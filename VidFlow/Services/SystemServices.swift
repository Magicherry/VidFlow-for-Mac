import AppKit
import Observation
import ServiceManagement
import UserNotifications
import VidFlowCore

/// macOS notifications: download finished / failed, "video link copied" prompts, updates.
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    private var center: UNUserNotificationCenter? {
        // Without a bundle (unit test hosts) the notification center traps.
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func start() {
        guard let center else { return }
        center.delegate = self
        let categories: [UNNotificationCategory] = [
            UNNotificationCategory(identifier: "completed", actions: [
                UNNotificationAction(identifier: "play", title: L.get("Action_Play"), options: [.foreground]),
                UNNotificationAction(identifier: "reveal", title: L.get("Menu_ShowInFinder"), options: [.foreground]),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: "batch", actions: [
                UNNotificationAction(identifier: "reveal", title: L.get("Menu_ShowInFinder"), options: [.foreground]),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: "link", actions: [
                UNNotificationAction(identifier: "parse", title: L.get("Action_Download"), options: [.foreground]),
            ], intentIdentifiers: []),
        ]
        center.setNotificationCategories(Set(categories))
    }

    /// Asked for only when there's something to say, not at first launch.
    private func show(_ title: String, _ body: String, category: String = "", userInfo: [String: String] = [:]) {
        guard let center else { return }
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.categoryIdentifier = category
            content.userInfo = userInfo
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    func downloadCompleted(title: String, file: URL?, folder: URL) {
        show(L.get("Notify_Completed"), title, category: "completed", userInfo: ["path": (file ?? folder).path])
    }

    func batchCompleted(count: Int, folder: URL?) {
        show(L.format("Notify_BatchCompleted", count), "", category: "batch", userInfo: ["path": folder?.path ?? ""])
    }

    func downloadFailed(title: String, reason: String) {
        show(L.get("Notify_Failed"), "\(title)\n\(reason.split(separator: "\n").first ?? "")", userInfo: ["action": "downloads"])
    }

    func diskFull(title: String, free: String) { show(L.format("Notify_DiskFull", free), title, userInfo: ["action": "downloads"]) }

    func downloadStalled(title: String) { show(L.get("Notify_Stalled"), title, userInfo: ["action": "downloads"]) }

    func linkDetected(_ url: String) {
        show(L.get("Notify_LinkDetected"), url, category: "link", userInfo: ["url": url])
    }

    func updateAvailable(version: String) {
        show(L.format("Notify_UpdateAvailable", version), L.get("Notify_UpdateAvailableBody"), userInfo: ["action": "updates"])
    }

    func updateReady(version: String) {
        show(L.format("Notify_UpdateReady", version), L.get("Notify_UpdateReadyBody"), userInfo: ["action": "updates"])
    }

    func updateResult(succeeded: Bool, version: String, current: String) {
        show(succeeded ? L.format("Notify_UpdateDone", version) : L.format("Notify_UpdateRolledBack", version),
             succeeded ? L.get("Notify_UpdateDoneBody") : L.format("Notify_UpdateRolledBackBody", current), userInfo: ["action": "updates"])
    }

    nonisolated func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        let path = info["path"] as? String
        let url = info["url"] as? String
        let target = info["action"] as? String
        await MainActor.run {
            let model = AppModel.shared
            switch action {
            case "play":
                if let path { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            case "reveal":
                if let path { Finder.reveal(URL(fileURLWithPath: path)) }
            default:
                if let url {
                    model.open(links: url)
                } else if target == "updates" {
                    model.openSettings(.updates)
                } else {
                    model.sidebar = target == "downloads" ? .downloads(.failed) : .downloads(.all)
                    model.showMainWindow()
                }
            }
        }
    }
}

enum Finder {
    static func reveal(_ url: URL) {
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            try? AppPaths.ensureDirectory(url)
            NSWorkspace.shared.open(url)
        }
    }
}

/// Optional: when a supported link is copied while VidFlow is in the background, offer to download it with a
/// notification. macOS has no clipboard-changed event, so the change count is compared on a slow timer, and only while
/// the setting is on. Reading the text at all can show the system's paste privacy prompt, so it stays off by default.
final class ClipboardWatcher {
    private var timer: Timer?
    private var lastChange = NSPasteboard.general.changeCount
    private var lastURL: String?

    func update(watching: Bool) {
        timer?.invalidate()
        timer = nil
        guard watching else { return }
        lastChange = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer?.tolerance = 0.5
    }

    private func check() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChange else { return }
        lastChange = pasteboard.changeCount
        // Links copied while VidFlow is in front are left alone (the user is pasting themselves).
        guard !NSApp.isActive, let url = UrlTools.extractURL(pasteboard.string(forType: .string)),
              UrlTools.isSupported(url), url != lastURL else { return }
        lastURL = url
        NotificationService.shared.linkDetected(url)
    }
}

/// Open at login, through the system's own login items list.
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isOn: Bool { status == .enabled || status == .requiresApproval }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.warn("Login item change failed: \(error.localizedDescription)")
        }
    }
}

/// Native folder and file choosers.
enum Pickers {
    static func folder(startingAt path: String? = nil) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let path { panel.directoryURL = URL(fileURLWithPath: path) }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    static func file() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

enum ToolState: Equatable {
    case checking, upToDate, updateAvailable, missing, systemCopy, bundled, checkFailed, installing
}

/// One external component and where it stands.
@Observable
final class ComponentStatus: Identifiable {
    let tool: Tool
    var state: ToolState = .checking
    var version: String?
    var latest: String?
    /// Install progress in percent; nil until the download reports its size.
    var progress: Double?
    init(tool: Tool) { self.tool = tool }
    var id: String { tool.id }
}

/// Checks and installs the external components for the whole app, so an install keeps going when Settings is closed.
/// With automatic updates on, checks once a day in the background and updates VidFlow's own copies while nothing is
/// downloading. Missing components are only installed when the user asks.
@Observable
final class ComponentsModel {
    let components: [ComponentStatus] = Tool.allCases.map { ComponentStatus(tool: $0) }
    private(set) var checking = false
    private(set) var installing = false
    private(set) var lastCheck: Date?
    /// Outcome of the last install, shown in Settings until replaced.
    var lastResult: (succeeded: Bool, message: String)?

    @ObservationIgnored private let tools: ToolManager
    @ObservationIgnored private var timer: Timer?

    private static let autoInterval: TimeInterval = 86400

    init(tools: ToolManager) { self.tools = tools }

    /// First automatic check a minute after startup, out of the way of whatever the user opened VidFlow for.
    func start() {
        Task { await refresh(remote: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        Task { await autoUpdate() }
        // Not due, or put off because something was downloading: look again in an hour.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    var missing: [ComponentStatus] { components.filter { $0.state == .missing } }
    var hasYtDlp: Bool {
        _ = components.first?.state // Redraws whoever asks when an install finishes.
        return tools.path(.ytDlp) != nil
    }

    /// Reads the installed versions and, with `remote`, compares VidFlow's own copies with the latest releases.
    func refresh(remote: Bool) async {
        guard !installing, !checking else { return }
        checking = true
        for c in components {
            c.state = tools.path(c.tool) == nil ? .missing : .checking
            c.version = nil
        }
        let checks = components.map { c in Task { await check(c, remote: remote) } }
        for check in checks { await check.value }
        if remote { lastCheck = Date() }
        checking = false
    }

    private func check(_ c: ComponentStatus, remote: Bool) async {
        guard let exe = tools.path(c.tool) else { return }
        c.version = await tools.installedVersion(c.tool)
        if tools.isInsideApp(exe) {
            c.state = .bundled
            return
        }
        guard tools.isManaged(exe) else {
            // A copy the user installed themselves is theirs to update; Settings offers to install VidFlow's own.
            c.state = .systemCopy
            return
        }
        guard remote else {
            c.state = .upToDate
            return
        }
        c.latest = await tools.latestVersion(c.tool)
        c.state = c.latest == nil ? .checkFailed
            : ToolManager.isUpToDate(c.tool, installed: c.version, latest: c.latest) ? .upToDate : .updateAvailable
    }

    /// Installs (or updates) the given components one after another, then checks again. Returns false if one failed.
    @discardableResult
    func install(_ list: [ComponentStatus]) async -> Bool {
        guard !installing, !checking, !list.isEmpty else { return true }
        installing = true
        lastResult = nil
        var done: [String] = []
        var ok = true
        do {
            for c in list {
                c.state = .installing
                c.progress = nil
                let tools = self.tools
                let tool = c.tool
                try await Task.detached {
                    try await tools.install(tool) { p in
                        Task { @MainActor in c.progress = p }
                    }
                }.value
                let version = await tools.installedVersion(tool)
                done.append("\(tool.rawValue) \(version ?? "")".trimmingCharacters(in: .whitespaces))
                Log.info("Installed \(done[done.count - 1])")
            }
            lastResult = (true, L.format("Tools_InstallDoneMessage", done.joined(separator: ", ")))
        } catch {
            Log.warn("Tool install failed: \(error.localizedDescription)")
            lastResult = (false, L.format("Settings_InstallFailedMessage", error.localizedDescription))
            ok = false
        }
        installing = false
        await refresh(remote: false)
        return ok
    }

    /// Reinstalls VidFlow's own copies, for when one has been damaged; also installs whatever is missing.
    func repair() async {
        await install(components.filter { c in
            guard let path = tools.path(c.tool) else { return true }
            return tools.isManaged(path)
        })
    }

    /// Once a day: update VidFlow's own copies that are out of date. Waits while anything downloads, and tries again
    /// later if a check or an install fails.
    private func autoUpdate() async {
        let model = AppModel.shared
        guard model.settings.autoUpdateComponents,
              Date().timeIntervalSince(model.settings.lastComponentUpdateCheck ?? .distantPast) >= Self.autoInterval,
              !installing, !checking, model.downloads.activeCount == 0 else { return }
        await refresh(remote: true)
        let due = components.filter { $0.state == .updateAvailable }
        // Something may have started while checking.
        guard model.downloads.activeCount == 0 else { return }
        if !due.isEmpty {
            Log.info("Updating in the background: \(due.map { "\($0.tool.rawValue) \($0.version ?? "?") → \($0.latest ?? "?")" }.joined(separator: ", "))")
            if await !install(due) { return }
        }
        if components.contains(where: { $0.state == .checkFailed }) { return }
        model.settings.lastComponentUpdateCheck = Date()
    }
}

enum UpdateState: Equatable { case idle, checking, upToDate, available, downloading, ready, failed }

/// Drives app updates: checks at startup and every 6 hours (unless the mode is manual), downloads automatically in
/// "auto" mode, and installs on the user's confirmation or as they quit. See `UpdateService`.
@Observable
final class UpdateModel {
    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }

    private(set) var state: UpdateState = .idle
    private(set) var latest: UpdateManifest?
    private(set) var progress: Double = 0
    private(set) var error: String?
    private(set) var lastResult: (outcome: UpdateOutcome, version: String?) = (.none, nil)
    var isInstallingNow = false

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var notifiedVersion: String?
    @ObservationIgnored private var busy = false
    /// The verified archive once `state` is `.ready`.
    @ObservationIgnored private var archive: URL?

    /// A newer version than the running one is known (whether or not it has been downloaded yet).
    var hasNewer: Bool { latest.map { UpdateService.isNewer($0.version, than: Self.currentVersion) } ?? false }

    /// A development build (ad-hoc signed) can't verify a new version, so it only points at the release page.
    var canSelfUpdate: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["VIDFLOW_UPDATE_ALLOW_UNSIGNED"] == "1" { return true }
        #endif
        return CodeIdentity.teamIdentifier(of: Bundle.main.bundleURL) != nil
    }

    func start() {
        lastResult = UpdateService.checkPendingResult(current: Self.currentVersion)
        if lastResult.outcome != .none, let version = lastResult.version {
            NotificationService.shared.updateResult(succeeded: lastResult.outcome == .succeeded, version: version, current: Self.currentVersion)
        }
        // First check shortly after startup (not during it), then periodically.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        if AppModel.shared.settings.updateMode != "manual" { Task { await check(userInitiated: false) } }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func check(userInitiated: Bool) async {
        guard !busy else { return }
        busy = true
        set(.checking)
        do {
            let manifest = try await UpdateService.fetchManifest()
            AppModel.shared.settings.lastUpdateCheck = Date()
            latest = manifest
            guard UpdateService.isNewer(manifest.version, than: Self.currentVersion) else {
                set(.upToDate)
                busy = false
                return
            }
            Log.info("Update available: \(manifest.version)")
            if AppModel.shared.settings.updateMode == "auto", canSelfUpdate {
                busy = false
                await download()
                return
            }
            set(.available)
            if !userInitiated, notifiedVersion != manifest.version {
                notifiedVersion = manifest.version
                NotificationService.shared.updateAvailable(version: manifest.version)
            }
        } catch {
            Log.warn("Update check failed: \(error.localizedDescription)")
            // No release published yet isn't worth a warning unless someone asked.
            if !userInitiated, (error as? HTTPStatusError)?.code == 404 { set(.idle) } else { fail(error) }
        }
        busy = false
    }

    func download() async {
        guard !busy, let manifest = latest else { return }
        busy = true
        progress = 0
        set(.downloading)
        do {
            archive = try await UpdateService.download(manifest) { [weak self] p in
                Task { @MainActor in self?.progress = p }
            }
            set(.ready)
            if notifiedVersion != manifest.version {
                notifiedVersion = manifest.version
                NotificationService.shared.updateReady(version: manifest.version)
            }
        } catch {
            Log.warn("Update download failed: \(error.localizedDescription)")
            fail(error)
        }
        busy = false
    }

    /// Installing replaces the app bundle, which needs it to be somewhere the user can write (not a disk image).
    private var canWriteApp: Bool {
        let app = Bundle.main.bundleURL
        return !app.path.hasPrefix("/Volumes/") && FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
    }

    /// Asks for confirmation (mentioning running downloads), then quits and swaps the app.
    func installNow() async {
        guard let manifest = latest, let archive else { return }
        guard canWriteApp else {
            error = L.get("Update_MoveToApplications")
            set(.failed)
            return
        }
        let alert = NSAlert()
        alert.messageText = L.format("Update_InstallTitle", manifest.version)
        let active = AppModel.shared.downloads.activeCount
        alert.informativeText = active > 0 ? L.format("Update_InstallBodyActive", active) : L.get("Update_InstallBody")
        alert.addButton(withTitle: L.get("Update_InstallNow"))
        alert.addButton(withTitle: L.get("Update_Later"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let app = try await UpdateService.unpack(archive, runningApp: Bundle.main.bundleURL, allowUnsigned: allowUnsigned)
            try UpdateService.installAfterExit(newApp: app, replacing: Bundle.main.bundleURL, version: manifest.version, relaunch: true)
            isInstallingNow = true
            self.archive = nil
            NSApp.terminate(nil)
        } catch {
            Log.warn("Update install failed: \(error.localizedDescription)")
            fail(error)
        }
    }

    /// Called as VidFlow quits: a downloaded update installs now, silently, so the next start is the new version
    /// without asking.
    func installOnQuit() {
        guard state == .ready, let manifest = latest, let archive, canWriteApp else { return }
        let semaphore = DispatchSemaphore(value: 0)
        let running = Bundle.main.bundleURL
        let allow = allowUnsigned
        Task.detached {
            do {
                let app = try await UpdateService.unpack(archive, runningApp: running, allowUnsigned: allow)
                try UpdateService.installAfterExit(newApp: app, replacing: running, version: manifest.version, relaunch: false)
            } catch {
                Log.warn("Install on quit failed: \(error.localizedDescription)")
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 8)
    }

    private var allowUnsigned: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["VIDFLOW_UPDATE_ALLOW_UNSIGNED"] == "1"
        #else
        false
        #endif
    }

    /// No raw HTTP messages in the UI.
    private func fail(_ err: Error) {
        error = switch err {
        case let status as HTTPStatusError where status.code == 404: L.get("Update_NoManifest")
        case is HTTPStatusError, is URLError: L.get("Update_Network")
        case is DecodingError: L.get("Update_BadManifest")
        default: err.localizedDescription
        }
        set(.failed)
    }

    private func set(_ new: UpdateState) {
        state = new
        if new != .failed { error = nil }
    }
}
