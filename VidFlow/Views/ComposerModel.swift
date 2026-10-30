import AppKit
import Observation
import VidFlowCore

/// One link of a multi-link paste: parsed in the background, then shown with a checkbox.
@Observable
final class BatchEntry: Identifiable {
    let id = UUID()
    let url: String
    var title: String
    var meta = L.get("Batch_Parsing")
    var isLoading = true
    var failed = false
    var selected = false
    /// Set once parsed: a single video or a playlist / multi-part video.
    var info: MediaInfo?

    init(url: String) {
        self.url = url
        title = url
    }

    /// How many downloads this row adds (a playlist adds all of its entries).
    var taskCount: Int {
        if case .playlist(let p) = info { return p.entries.count }
        return 1
    }

    func setResult(_ info: MediaInfo) {
        self.info = info
        title = info.title
        var parts = [info.platform.displayName]
        switch info {
        case .playlist(let p): parts.append(L.format("Batch_PlaylistMeta", p.entries.count))
        case .video(let v): if let d = v.duration, d > 0 { parts.append(Format.duration(d)) }
        }
        if let uploader = info.uploader, !uploader.isEmpty { parts.append(uploader) }
        meta = parts.joined(separator: " · ")
        isLoading = false
    }

    func setError(_ message: String) {
        failed = true
        meta = message.split(separator: "\n").first.map(String.init) ?? message
        isLoading = false
    }
}

enum ComposerResult: Equatable {
    case empty, loading
    case video(VideoInfo)
    case playlist(PlaylistInfo)
    case batch
}

struct ComposerMessage: Equatable {
    enum Kind { case info, warning, error, success }
    var kind: Kind
    var title: String?
    var text: String
    var loginPlatform: Platform?
    var showDownloads = false
    var openComponents = false
}

/// The New Download page's state: the link, what it parsed to and the options of this task. Kept here rather than in
/// the view so that switching to another page and back loses nothing.
@Observable
final class ComposerModel {
    var urlText = ""
    var result: ComposerResult = .empty
    var message: ComposerMessage?
    /// Template the current task started from; `options` is a copy, so a per-task change never touches the template.
    var template: DownloadTemplate
    var options: DownloadTemplate
    var batch: [BatchEntry] = []
    var selectedEntries = Set<Int>()
    var batchSelectionTouched = false
    var confirmMany: Int?
    /// Links already downloaded, waiting for the user to say what to do.
    var confirmDuplicates: Set<String>?
    @ObservationIgnored private var skipURLs = Set<String>()
    @ObservationIgnored private var overwriteURLs = Set<String>()

    @ObservationIgnored private var parseTask: Task<Void, Never>?
    @ObservationIgnored private var batchQueue: ArraySlice<BatchEntry> = []

    init() {
        let t = TemplateStore().defaultTemplate(SettingsStore.shared.current)
        template = t
        options = t
    }

    private var app: AppModel { .shared }

    var video: VideoInfo? {
        if case .video(let v) = result { return v }
        return nil
    }

    var playlist: PlaylistInfo? {
        if case .playlist(let p) = result { return p }
        return nil
    }

    var isModified: Bool { !options.sameOptions(as: template) }

    func use(_ t: DownloadTemplate) {
        template = t
        options = t
    }

    func saveAsTemplate(name: String) {
        var copy = options
        copy.id = UUID()
        copy.nameKey = nil
        copy.name = name
        app.templates.save(copy)
        use(copy)
    }

    // ---- Links --------------------------------------------------------------------------------------------------

    func load(text: String) {
        let urls = UrlTools.extractURLs(text)
        guard !urls.isEmpty else {
            message = ComposerMessage(kind: .warning, text: L.get("Home_NoLink"))
            return
        }
        urlText = urls.joined(separator: " ")
        parse()
    }

    func paste() {
        let text = NSPasteboard.general.string(forType: .string)
        if UrlTools.extractURLs(text).isEmpty {
            message = ComposerMessage(kind: .info, text: L.get("Home_ClipboardEmpty"))
        } else if let text {
            load(text: text)
        }
    }

    /// A supported link already on the clipboard saves a step when the page opens.
    func prefillFromClipboard() {
        guard urlText.isEmpty, let url = UrlTools.extractURL(NSPasteboard.general.string(forType: .string)),
              UrlTools.isSupported(url) else { return }
        urlText = url
    }

    func clear() {
        parseTask?.cancel()
        urlText = ""
        result = .empty
        batch = []
        message = nil
    }

    func cancelParse() {
        parseTask?.cancel()
        result = .empty
    }

    func parse() {
        let urls = UrlTools.extractURLs(urlText)
        guard !urls.isEmpty else {
            message = ComposerMessage(kind: .warning, text: L.get("Home_InvalidLink"))
            return
        }
        guard app.tools.path(.ytDlp) != nil else {
            message = ComposerMessage(kind: .warning, title: L.get("Home_ToolsMissingTitle"), text: L.get("Home_ToolsMissingMessage"), openComponents: true)
            return
        }
        parseTask?.cancel()
        message = nil
        batch = []
        app.browserCookiesFailed = false
        if urls.count > 1 {
            parseBatch(urls)
            return
        }
        let url = urls[0]
        urlText = url
        result = .loading
        let service = app.service
        parseTask = Task { [weak self] in
            do {
                let info = try await service.info(url: url)
                guard !Task.isCancelled, let self else { return }
                switch info {
                case .video(let v): self.result = .video(v)
                case .playlist(let p):
                    self.selectedEntries = Set(p.entries.map(\.index))
                    self.result = .playlist(p)
                }
                self.showHints(info.platform)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.result = .empty
                self.message = ComposerMessage(kind: .error, title: L.get("Home_ParseFailed"), text: error.localizedDescription)
            }
        }
    }

    /// Several links: list them at once, parse them 3 at a time, and tick each one that parses so the user can untick
    /// what they don't want. Failed links stay unticked with the reason shown.
    private func parseBatch(_ urls: [String]) {
        let entries = urls.map(BatchEntry.init)
        batch = entries
        batchSelectionTouched = false
        result = .batch
        if urls.contains(where: { !UrlTools.isSupported($0) }) {
            message = ComposerMessage(kind: .info, text: L.get("Batch_UnsupportedHint"))
        }
        batchQueue = entries[...]
        parseTask = Task { [weak self] in
            let workers = (0..<3).map { _ in Task { await self?.parseBatchEntries() } }
            await withTaskCancellationHandler {
                for worker in workers { await worker.value }
            } onCancel: {
                workers.forEach { $0.cancel() }
            }
        }
    }

    private func parseBatchEntries() async {
        let service = app.service
        while !Task.isCancelled, let entry = batchQueue.popFirst() {
            do {
                let info = try await service.info(url: entry.url)
                guard !Task.isCancelled else { return }
                entry.setResult(info)
                if !batchSelectionTouched { entry.selected = true }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { entry.setError(error.localizedDescription) }
            }
        }
    }

    private func showHints(_ platform: Platform) {
        if app.browserCookiesFailed {
            message = ComposerMessage(kind: .warning, title: L.get("Home_BrowserCookiesFailedTitle"), text: L.get("Home_BrowserCookiesFailed"),
                                      loginPlatform: platform == .other || !CookieVault.signInPlatforms.contains(platform) ? nil : platform)
        } else if app.tools.path(.ffmpeg) == nil {
            message = ComposerMessage(kind: .warning, title: L.get("Home_NoFfmpegTitle"), text: L.get("Home_NoFfmpeg"), openComponents: true)
        } else if platform == .youTube, app.tools.path(.deno) == nil {
            message = ComposerMessage(kind: .info, title: L.get("Home_NoDenoTitle"), text: L.get("Home_NoDeno"), openComponents: true)
        } else if platform == .bilibili, !app.vault.isLoggedIn(.bilibili), app.settings.cookiesBrowser.isEmpty, app.settings.cookiesFile.isEmpty {
            message = ComposerMessage(kind: .info, title: L.get("Home_BiliLoginHintTitle"), text: L.get("Home_BiliLoginHint"), loginPlatform: .bilibili)
        }
    }

    /// Signs in, then parses again so the quality list reflects what the account can access.
    func signIn(_ platform: Platform) {
        let url = video?.url ?? playlist?.url
        message = nil
        Task {
            await LoginWindowController.show(platform)
            if app.vault.isLoggedIn(platform), let url {
                urlText = url
                parse()
            }
        }
    }

    // ---- Queueing -----------------------------------------------------------------------------------------------

    var selectedBatchEntries: [BatchEntry] { batch.filter { $0.selected && $0.info != nil } }

    var downloadCount: Int {
        switch result {
        case .video: 1
        case .playlist: selectedEntries.count
        case .batch: selectedBatchEntries.reduce(0) { $0 + $1.taskCount }
        default: 0
        }
    }

    var downloadTitle: String {
        switch result {
        case .playlist: L.format("Download_Selected", selectedEntries.count)
        case .batch: L.format("Download_Selected", selectedBatchEntries.count)
        default: L.get("Download_Start")
        }
    }

    /// Everything the Download button would add, as (request, title, thumbnail, part).
    private func pendingRequests() -> [(request: DownloadRequest, title: String, thumbnail: String?, part: Int?)] {
        let folder = app.settings.downloadFolder
        let options = self.options
        func entries(_ p: PlaylistInfo, only: Set<Int>?) -> [(request: DownloadRequest, title: String, thumbnail: String?, part: Int?)] {
            // Each playlist goes into its own subfolder.
            let sub = (folder as NSString).appendingPathComponent(UrlTools.safeFolderName(p.title))
            return p.entries.filter { only?.contains($0.index) ?? true }.map {
                (options.toRequest(url: $0.url, baseFolder: sub), $0.title, $0.thumbnailURL ?? p.thumbnailURL, $0.index)
            }
        }
        switch result {
        case .video(let v):
            return [(options.toRequest(url: v.url, baseFolder: folder), v.title, v.thumbnailURL, nil)]
        case .playlist(let p):
            return entries(p, only: selectedEntries)
        case .batch:
            return selectedBatchEntries.flatMap { entry -> [(request: DownloadRequest, title: String, thumbnail: String?, part: Int?)] in
                switch entry.info {
                case .playlist(let p): return entries(p, only: nil)
                case .video(let v): return [(options.toRequest(url: v.url, baseFolder: folder), v.title, v.thumbnailURL, nil)]
                case nil: return []
                }
            }
        default:
            return []
        }
    }

    /// Checks for what's already in the list, then for a huge playlist / multi-part video added with one click.
    func requestDownload() {
        let pending = pendingRequests()
        guard !pending.isEmpty else { return }
        let found = DownloadDuplicates.find(pending.map(\.request), among: app.downloads.items.map(\.record))
        // Running or waiting: the same file can't be downloaded twice at once.
        skipURLs = found.active
        overwriteURLs = []
        if !found.completed.isEmpty {
            confirmDuplicates = found.completed
        } else if pending.allSatisfy({ found.active.contains($0.request.url) }) {
            message = ComposerMessage(kind: .info, text: L.get("Home_AlreadyQueued"), showDownloads: true)
        } else {
            confirmCount()
        }
    }

    /// The user's answer about links already downloaded.
    func resolveDuplicates(downloadAgain: Bool) {
        guard let completed = confirmDuplicates else { return }
        confirmDuplicates = nil
        if downloadAgain { overwriteURLs = completed } else { skipURLs.formUnion(completed) }
        if pendingRequests().allSatisfy({ skipURLs.contains($0.request.url) }) { return }
        confirmCount()
    }

    private func confirmCount() {
        let count = pendingRequests().filter { !skipURLs.contains($0.request.url) }.count
        if count > 50 { confirmMany = count } else { enqueue() }
    }

    func enqueue() {
        let pending = pendingRequests().filter { !skipURLs.contains($0.request.url) }
        guard !pending.isEmpty else { return }
        let downloads = app.downloads
        downloads.batch {
            for item in pending {
                var request = item.request
                request.overwrite = overwriteURLs.contains(request.url)
                downloads.enqueue(request, title: item.title, thumbnailURL: item.thumbnail, partIndex: item.part)
            }
        }
        let added = pending.count == 1 ? L.format("Home_AddedOne", pending[0].title) : L.format("Home_AddedMany", pending.count)
        result = .empty
        batch = []
        urlText = ""
        message = ComposerMessage(kind: .success, title: L.get("Home_Added"), text: added, showDownloads: true)
    }
}
