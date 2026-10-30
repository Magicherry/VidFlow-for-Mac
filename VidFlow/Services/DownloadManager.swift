import AppKit
import Network
import Observation
import SwiftUI
import VidFlowCore

/// View model for one row of the download list. What rows show is observed field by field, so a progress update redraws
/// that row's cell and not the whole table; `record` assembles the persisted form when saving.
@Observable
final class DownloadItem: Identifiable {
    var state: DownloadState
    var title: String
    var thumbnailURL: String?
    var progress: Double
    var statusText: String
    var filePath: String?
    var errorDetail: String?
    var speed: Double = 0
    var eta: Double = 0
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    /// Finished, but the file is no longer where it was saved.
    var fileMissing = false

    @ObservationIgnored let id: UUID
    @ObservationIgnored let platform: Platform
    @ObservationIgnored let createdAt: Date
    @ObservationIgnored let partIndex: Int?
    @ObservationIgnored var request: DownloadRequest
    @ObservationIgnored var priorityAt: Date?
    @ObservationIgnored var expectedPath: String?

    @ObservationIgnored var task: Task<Void, Never>?
    /// Set when the running process is being stopped for a pause rather than a cancel.
    @ObservationIgnored var pauseRequested = false
    /// Set when it is being stopped to start over (it stalled).
    @ObservationIgnored var restartRequested = false
    /// Last time yt-dlp reported anything; used to detect stalled downloads.
    @ObservationIgnored var lastActivity = Date()
    @ObservationIgnored var stallReported = false
    @ObservationIgnored var lastProgressShown = Date.distantPast
    /// Automatic attempts so far, and when the next may start; while nil it can start as soon as there's a slot.
    @ObservationIgnored var retries = 0
    @ObservationIgnored var notBefore: Date?
    @ObservationIgnored var progressAtLastFailure = 0.0
    /// Gave up on a network problem: gets another go when the network comes back.
    @ObservationIgnored var failedOnNetwork = false

    init(_ record: DownloadRecord) {
        id = record.id
        platform = UrlTools.detectPlatform(record.request.url)
        createdAt = record.createdAt
        partIndex = record.partIndex
        request = record.request
        priorityAt = record.priorityAt
        expectedPath = record.expectedPath
        state = record.state
        title = record.title
        thumbnailURL = record.thumbnailURL
        progress = record.state == .completed ? 100 : record.progress
        statusText = record.statusText ?? L.get("Status_Waiting")
        filePath = record.filePath
        errorDetail = record.errorDetail
    }

    var record: DownloadRecord {
        var r = DownloadRecord(request: request, title: title, thumbnailURL: thumbnailURL, partIndex: partIndex)
        r.id = id
        r.state = state
        r.filePath = filePath
        r.statusText = statusText
        r.errorDetail = errorDetail
        r.createdAt = createdAt
        r.priorityAt = priorityAt
        r.progress = progress
        r.expectedPath = expectedPath
        return r
    }

    var label: String { DownloadLabels.label(request, partIndex: partIndex) }

    /// Queued or running: counts toward the badge and blocks removal.
    var isActive: Bool { state == .queued || state == .downloading || state == .processing }
    var isRunning: Bool { state == .downloading || state == .processing }
    var canPause: Bool { state == .queued || state == .downloading }
    var canResume: Bool { state == .paused }
    var canRetry: Bool { state == .failed || state == .canceled || (state == .completed && fileMissing) }
    var canRemove: Bool { !isActive }
    var canCancel: Bool { isActive || state == .paused }
    var canPrioritize: Bool { state == .queued }
    var existingFile: URL? {
        guard let path = filePath, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// The folder this download's file is in, as far as it is known.
    var folder: URL {
        existingFile?.deletingLastPathComponent() ?? URL(fileURLWithPath: request.outputFolder)
    }
}

/// Owns the download queue: runs up to `AppSettings.maxConcurrent` jobs, persists the list, supports pause/resume, retries
/// what the network broke, stops before the disk fills, and reports overall progress (Dock, menu bar, notifications).
/// Used from the main actor.
@Observable
final class DownloadManager {
    private(set) var items: [DownloadItem] = []

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var completedSinceIdle = 0
    @ObservationIgnored private var lastCompletedFolder: URL?
    /// Keeps the Mac from sleeping and App Nap from throttling while something downloads.
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var shuttingDown = false
    @ObservationIgnored private var batching = false
    @ObservationIgnored private let saveQueue = DispatchQueue(label: "VidFlow.saveDownloads", qos: .utility)
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var online = true

    /// Finished rows kept across launches; older ones are dropped so the list and its file don't grow forever.
    private static let historyLimit = 2000
    private static let progressInterval: TimeInterval = 0.25
    private static var stallAfter: TimeInterval {
        #if DEBUG
        if let s = ProcessInfo.processInfo.environment["VIDFLOW_STALL_SECONDS"].flatMap(Double.init) { return s }
        #endif
        return 180
    }

    #if DEBUG
    /// Lets the debug driver pretend the disk is nearly full.
    @ObservationIgnored var debugFreeBytes: Int64?
    #endif

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(online: up) }
        }
        pathMonitor.start(queue: .global(qos: .utility))
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFiles() }
        }
    }

    var activeCount: Int { items.lazy.filter(\.isActive).count }
    var runningCount: Int { items.lazy.filter(\.isRunning).count }
    var canPauseAny: Bool { items.contains(where: \.canPause) }
    var canResumeAny: Bool { items.contains(where: \.canResume) }
    var canClearFinished: Bool { items.contains { $0.state == .completed || $0.state == .failed || $0.state == .canceled } }

    var overallProgress: Double {
        let active = items.filter(\.isActive)
        return active.isEmpty ? 0 : active.map(\.progress).reduce(0, +) / Double(active.count)
    }

    func count(_ filter: DownloadStatusFilter) -> Int {
        filter == .all ? items.count : items.lazy.filter { DownloadFilter.group(of: $0.state) == filter }.count
    }

    func loadPersisted() {
        var finished = 0
        let records = DownloadStore.load().sorted { $0.createdAt > $1.createdAt }.filter { r in
            guard r.state == .completed || r.state == .failed || r.state == .canceled else { return true }
            finished += 1
            return finished <= Self.historyLimit
        }
        items = records.map { record in
            var record = record
            // Re-create status text in the current language (the app language may have changed).
            if let status = DownloadLabels.restingStatus(record) { record.statusText = status }
            return DownloadItem(record)
        }
        refreshFiles()
        changed()
    }

    /// Adds a download. Title/thumbnail may be provisional (batch links): yt-dlp fills them in.
    func enqueue(_ request: DownloadRequest, title: String, thumbnailURL: String?, partIndex: Int? = nil) {
        items.insert(DownloadItem(DownloadRecord(request: request, title: title, thumbnailURL: thumbnailURL, partIndex: partIndex)), at: 0)
        changed()
    }

    /// Runs `body` with the follow-up work held back, so adding a long playlist isn't quadratic.
    func batch(_ body: () -> Void) {
        batching = true
        body()
        batching = false
        changed()
    }

    func pause(_ item: DownloadItem) {
        guard item.canPause else { return }
        if item.state == .queued {
            item.notBefore = nil
            setPaused(item)
        } else {
            item.pauseRequested = true
            item.task?.cancel()
        }
        changed()
    }

    func resume(_ item: DownloadItem) {
        guard item.canResume else { return }
        item.retries = 0
        item.state = .queued
        item.statusText = L.get("Status_Waiting")
        changed()
    }

    func pauseAll() { batch { items.filter(\.canPause).forEach(pause) } }
    func resumeAll() { batch { items.filter(\.canResume).forEach(resume) } }

    func cancel(_ item: DownloadItem) {
        if item.state == .queued || item.state == .paused {
            item.state = .canceled
            item.notBefore = nil
            item.statusText = L.get("Status_Canceled")
            cleanUp(item)
        } else {
            item.task?.cancel()
        }
        changed()
    }

    func retry(_ item: DownloadItem) {
        guard item.canRetry else { return }
        // A finished download whose file has gone: nothing to continue from, and yt-dlp's own records must not stop it.
        if item.state == .completed { item.request.overwrite = true }
        item.progress = 0
        item.retries = 0
        item.notBefore = nil
        item.failedOnNetwork = false
        item.fileMissing = false
        item.errorDetail = nil
        item.statusText = L.get("Status_Waiting")
        item.state = .queued
        changed()
    }

    func remove(_ item: DownloadItem) {
        guard item.canRemove else { return }
        if item.state == .failed || item.state == .canceled { cleanUp(item) }
        items.removeAll { $0 === item }
        changed()
    }

    func clearFinished() {
        let gone = items.filter { $0.state == .completed || $0.state == .failed || $0.state == .canceled }
        gone.filter { $0.state != .completed }.forEach(cleanUp)
        items.removeAll { $0.state == .completed || $0.state == .failed || $0.state == .canceled }
        changed()
    }

    /// "Download next": this queued item starts as soon as a slot is free.
    func prioritize(_ item: DownloadItem) {
        guard item.canPrioritize else { return }
        item.priorityAt = Date()
        item.notBefore = nil
        item.statusText = L.get("Status_Next")
        changed()
    }

    /// On quit: stop processes but keep running items as queued so they resume next launch.
    func shutdown() {
        shuttingDown = true
        for item in items where item.isRunning {
            item.pauseRequested = true // not a user cancel
            item.task?.cancel()
            item.state = .queued
        }
        let records = items.map(\.record)
        saveQueue.sync { DownloadStore.save(records) }
    }

    /// Working files of a download that won't continue. A little later: tools that were just stopped may still be closing theirs.
    private func cleanUp(_ item: DownloadItem) {
        guard let path = item.expectedPath else { return }
        let keepThumbnails = item.request.isCover
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(1.5))
            let removed = PartialFiles.remove(finalPath: path, keepThumbnails: keepThumbnails)
            if removed > 0 { Log.info("Removed \(removed) working files of a canceled download") }
        }
    }

    /// Finished files can be moved or deleted while VidFlow isn't looking.
    func refreshFiles() {
        let fm = FileManager.default
        for item in items where item.state == .completed {
            let missing = item.filePath.map { !fm.fileExists(atPath: $0) } ?? false
            if item.fileMissing != missing { item.fileMissing = missing }
        }
    }

    /// Call after any state change: saves, refreshes the Dock, and starts queued work.
    private func changed() {
        guard !batching else { return }
        scheduleSave()
        refreshDock()
        updateActivity()
        pump()
    }

    private func updateActivity() {
        let now = Date()
        let busy = items.contains { $0.isRunning || ($0.state == .queued && ($0.notBefore ?? now) <= now) }
        if busy, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Downloading videos")
        } else if !busy, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
    }

    private func pump() {
        guard !shuttingDown else { return }
        var running = runningCount
        let limit = max(1, AppModel.shared.settings.maxConcurrent)
        let now = Date()
        // Prioritized items first (most recently prioritized first), then oldest first (the list is newest-on-top).
        let queued = items.reversed().filter { $0.state == .queued && ($0.notBefore ?? now) <= now }
        if running < limit, !queued.isEmpty {
            let order = queued.enumerated().sorted { a, b in
                let (pa, pb) = (a.element.priorityAt ?? .distantPast, b.element.priorityAt ?? .distantPast)
                return pa != pb ? pa > pb : a.offset < b.offset
            }.map(\.element)
            for item in order {
                if running >= limit { break }
                if start(item) { running += 1 }
            }
        }

        if activeCount == 0, completedSinceIdle > 0 {
            if completedSinceIdle > 1, shouldNotify {
                NotificationService.shared.batchCompleted(count: completedSinceIdle, folder: lastCompletedFolder)
            }
            completedSinceIdle = 0
        }
    }

    private func freeBytes(for item: DownloadItem) -> Int64? {
        #if DEBUG
        if let debugFreeBytes { return debugFreeBytes }
        #endif
        return DiskSpace.free(at: item.request.outputFolder)
    }

    /// Stops a download for lack of room; it continues from where it was once the user frees some and resumes.
    private func pauseForDisk(_ item: DownloadItem) {
        let free = freeBytes(for: item).map { Format.bytes(Double($0)) } ?? "?"
        Log.warn("Not enough disk space (\(free) free): \(item.request.url)")
        item.speed = 0
        item.eta = 0
        item.state = .paused
        item.statusText = L.format("Status_DiskFull", free)
        if AppModel.shared.settings.notifyOnFailure { NotificationService.shared.diskFull(title: item.title, free: free) }
    }

    /// Returns false if it couldn't start.
    private func start(_ item: DownloadItem) -> Bool {
        if let free = freeBytes(for: item), !DiskSpace.hasRoom(free: free) {
            pauseForDisk(item)
            return false
        }
        item.state = .downloading
        item.statusText = L.get("Status_Connecting")
        item.pauseRequested = false
        item.restartRequested = false
        item.notBefore = nil
        item.lastActivity = Date()
        item.stallReported = false
        Log.info("Download start: \(item.request.url) (\(item.request.mode), \(item.request.maxHeight))")
        let service = AppModel.shared.service
        let request = item.request
        item.task = Task { [weak self] in
            do {
                // The service is nonisolated, so it runs and parses off the main actor and only reports back here.
                let path = try await service.download(request) { event in
                    Task { @MainActor in self?.apply(event, to: item) }
                }
                item.filePath = path ?? item.filePath
                item.progress = 100
                item.speed = 0
                item.eta = 0
                item.fileMissing = false
                item.request.overwrite = false
                item.state = .completed
                item.statusText = path.map { L.format("Status_CompletedFile", ($0 as NSString).lastPathComponent) } ?? L.get("Status_Completed")
                Log.info("Download done: \(path ?? "?")")
                self?.onCompleted(item)
            } catch is CancellationError {
                item.speed = 0
                item.eta = 0
                if item.restartRequested {
                    item.state = .queued
                    item.statusText = L.get("Status_Waiting")
                } else if item.pauseRequested {
                    self?.setPaused(item)
                } else {
                    item.state = .canceled
                    item.statusText = L.get("Status_Canceled")
                    self?.cleanUp(item)
                }
            } catch {
                self?.handleFailure(error, of: item)
            }
            item.task = nil
            self?.changed()
        }
        return true
    }

    private func handleFailure(_ error: Error, of item: DownloadItem) {
        item.speed = 0
        item.eta = 0
        let raw = (error as? YtDlpError)?.detail ?? error.localizedDescription
        if ErrorMapper.isDiskFull(raw) {
            pauseForDisk(item)
            return
        }
        if ErrorMapper.isTransient(raw) {
            // Headway made since the last failure earns the attempts back: a long download on a flaky line keeps going.
            if item.progress > item.progressAtLastFailure + 1 { item.retries = 0 }
            item.progressAtLastFailure = item.progress
            if !online {
                item.state = .queued
                item.notBefore = .distantFuture
                item.statusText = L.get("Status_WaitingNetwork")
                Log.info("Waiting for the network: \(item.request.url)")
                return
            }
            if item.retries < RetryPolicy.maxAttempts {
                item.retries += 1
                let delay = RetryPolicy.delay(attempt: item.retries)
                item.state = .queued
                item.notBefore = Date().addingTimeInterval(delay)
                item.statusText = L.format("Status_Retrying", Int(delay), item.retries, RetryPolicy.maxAttempts)
                Log.info("Retry \(item.retries) in \(Int(delay)) s: \(item.request.url): \(ErrorMapper.lastErrorLine(raw))")
                return
            }
            item.failedOnNetwork = true
        }
        item.state = .failed
        item.statusText = error.localizedDescription.replacingOccurrences(of: "\n", with: " ")
        item.errorDetail = (error as? YtDlpError)?.detail ?? String(describing: error)
        Log.warn("Download failed: \(item.request.url): \(error.localizedDescription)")
        if AppModel.shared.settings.notifyOnFailure, !NSApp.isActive {
            NotificationService.shared.downloadFailed(title: item.title, reason: error.localizedDescription)
        }
    }

    func networkChanged(online up: Bool) {
        guard up != online else { return }
        online = up
        Log.info(up ? "Network is back" : "Network is gone")
        guard up else { return }
        for item in items {
            if item.state == .queued, item.notBefore != nil {
                item.notBefore = nil
                item.retries = 0
                item.statusText = L.get("Status_Waiting")
            } else if item.state == .failed, item.failedOnNetwork {
                retry(item)
            }
        }
        changed()
    }

    private func onCompleted(_ item: DownloadItem) {
        completedSinceIdle += 1
        lastCompletedFolder = item.folder
        // A single download gets its own notification; batches get one summary when the queue empties.
        let othersActive = items.contains { $0 !== item && $0.isActive }
        if !othersActive, completedSinceIdle == 1, shouldNotify {
            NotificationService.shared.downloadCompleted(title: item.title, file: item.existingFile, folder: item.folder)
        }
    }

    private var shouldNotify: Bool { AppModel.shared.settings.notifyOnFinish && !NSApp.isActive }

    private func setPaused(_ item: DownloadItem) {
        item.state = .paused
        item.statusText = item.progress > 0 ? L.format("Status_PausedAt", String(format: "%.1f", item.progress)) : L.get("Status_Paused")
    }

    private func apply(_ event: DownloadEvent, to item: DownloadItem) {
        guard item.isRunning else { return }
        item.lastActivity = Date()
        item.stallReported = false
        switch event {
        case .started(_, let title, let thumbnail):
            // Batch links start with the URL as title; take the real one from yt-dlp.
            if let title, item.title != title { item.title = title }
            if item.thumbnailURL == nil { item.thumbnailURL = thumbnail }
            scheduleSave()
        case .expectedFile(let path):
            item.expectedPath = path
            scheduleSave()
        case .progress(let p):
            apply(p, to: item)
        case .file(let path):
            item.filePath = path
        }
    }

    private func apply(_ p: DownloadProgress, to item: DownloadItem) {
        if p.processing {
            item.state = .processing
            item.speed = 0
            item.eta = 0
            item.statusText = item.request.mode == "video" ? L.get("Status_Merging") : L.get("Status_Converting")
            refreshDock()
            return
        }
        // aria2c and fragmented streams report many times a second; the eye needs a few.
        let now = Date()
        guard p.streamFinished || now.timeIntervalSince(item.lastProgressShown) >= Self.progressInterval else { return }
        item.lastProgressShown = now
        if p.total > 0, let free = freeBytes(for: item), !DiskSpace.hasRoom(free: free, needed: p.total - p.downloaded) {
            item.pauseRequested = true
            item.task?.cancel()
            pauseForDisk(item)
            return
        }
        item.state = .downloading
        // One percentage for the whole download: the bar keeps going from video into audio instead of restarting.
        item.progress = p.percent
        item.speed = p.speed
        item.eta = p.eta
        item.downloadedBytes = p.downloaded
        item.totalBytes = p.total
        if p.streamFinished {
            item.statusText = L.get("Status_VideoDoneAudioNext")
        } else {
            var parts: [String] = []
            if p.parts > 1 { parts.append(p.part == 1 ? L.get("Status_VideoStream") : L.get("Status_AudioStream")) }
            parts.append(String(format: "%.1f%%", p.percent))
            item.statusText = parts.joined(separator: " · ")
        }
        refreshDock()
    }

    private func refreshDock() {
        var count = 0
        var sum = 0.0
        var allWaiting = true
        for item in items where item.isActive {
            count += 1
            sum += item.progress
            if item.state != .queued { allWaiting = false }
        }
        DockProgress.shared.update(active: count, percent: count > 0 ? sum / Double(count) : 0, indeterminate: allWaiting)
    }

    private func tick() {
        checkStalled()
        let now = Date()
        if items.contains(where: { $0.state == .queued && ($0.notBefore ?? .distantFuture) <= now }) { changed() }
    }

    /// A running download with no output from yt-dlp for a while is started over (it continues from what it has). When
    /// that has been tried, it is flagged and the user told.
    private func checkStalled() {
        for item in items where item.state == .downloading && !item.stallReported
            && Date().timeIntervalSince(item.lastActivity) > Self.stallAfter {
            if item.retries < RetryPolicy.maxAttempts {
                item.retries += 1
                item.restartRequested = true
                item.statusText = L.get("Status_Restarting")
                Log.warn("Download stalled, restarting (\(item.retries)): \(item.request.url)")
                item.lastActivity = Date()
                item.task?.cancel()
                continue
            }
            item.stallReported = true
            item.statusText = L.format("Status_Stalled", Int(Self.stallAfter / 60))
            Log.warn("Download stalled: \(item.request.url)")
            if AppModel.shared.settings.notifyOnFailure, !NSApp.isActive {
                NotificationService.shared.downloadStalled(title: item.title)
            }
        }
    }

    private func scheduleSave() {
        guard saveTask == nil else { return } // One is already on its way, and will see this change too.
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.saveTask = nil
            self?.saveNow()
        }
    }

    private func saveNow() {
        let records = items.map(\.record)
        saveQueue.async { DownloadStore.save(records) }
    }
}

/// Download progress on the Dock icon: a bar under the icon and a count badge.
final class DockProgress {
    static let shared = DockProgress()
    private let view = DockView()
    private var last: (Int, Int, Bool)?

    func update(active: Int, percent: Double, indeterminate: Bool) {
        let state = (active, Int(percent), indeterminate)
        if let last, last == state { return }
        last = state
        let tile = NSApp.dockTile
        tile.badgeLabel = active > 0 ? "\(active)" : nil
        view.progress = active > 0 && !indeterminate ? percent / 100 : nil
        if tile.contentView !== view { tile.contentView = view }
        tile.display()
    }

    private final class DockView: NSView {
        var progress: Double?

        override func draw(_: NSRect) {
            NSApp.applicationIconImage?.draw(in: bounds)
            guard let progress else { return }
            let track = NSRect(x: bounds.width * 0.12, y: bounds.height * 0.08, width: bounds.width * 0.76, height: bounds.height * 0.09)
            let radius = track.height / 2
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
            var fill = track.insetBy(dx: 1.5, dy: 1.5)
            fill.size.width = max(fill.height, fill.width * progress)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: fill, xRadius: fill.height / 2, yRadius: fill.height / 2).fill()
        }
    }
}
