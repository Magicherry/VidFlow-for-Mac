import AppKit
import Observation
import SwiftUI
import VidFlowCore

enum SidebarItem: Hashable {
    case newDownload
    case downloads(DownloadStatusFilter)
    case templates
    case accounts
}

enum SettingsTab: String, Hashable {
    case general, downloads, network, updates, about
}

/// The app's shared state. Everything UI-facing lives on the main actor; the work itself runs in VidFlowCore.
@Observable
final class AppModel {
    static let shared = AppModel()

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            SettingsStore.shared.current = settings
            SettingsStore.shared.save()
            if settings.theme != oldValue.theme { applyTheme() }
            if settings.watchClipboard != oldValue.watchClipboard { clipboard.update(watching: settings.watchClipboard) }
        }
    }

    var sidebar: SidebarItem = .newDownload
    /// Settings opens on the pane last used.
    var settingsTab: SettingsTab = SettingsTab(rawValue: UserDefaults.standard.string(forKey: "settingsTab") ?? "") ?? .general {
        didSet { UserDefaults.standard.set(settingsTab.rawValue, forKey: "settingsTab") }
    }
    var templates = TemplateStore()
    var showFirstRun = false
    var showOptionsInspector = false
    var showDownloadInspector = false
    /// Text handed to the New Download page from outside it: a drop, a notification, the menu bar.
    var pendingLinks: String?
    /// Bumped on sign-in or sign-out, so views reading `vault` refresh.
    var accountsRevision = 0
    var connectivity: ConnectivityResult?
    var connectivityChecking = false
    var browserCookiesFailed = false
    /// Set once the app is on its way out, so nothing restarts.
    var isTerminating = false

    let vault: CookieVault
    let tools: ToolManager
    let downloads: DownloadManager
    let components: ComponentsModel
    let updates: UpdateModel
    let clipboard = ClipboardWatcher()
    let composer = ComposerModel()
    @ObservationIgnored let douyin = DouyinFetcher()

    @ObservationIgnored lazy var service: YtDlpService = {
        let douyin = self.douyin
        return YtDlpService(tools: tools, vault: vault, fetchDouyinDetail: { url in
            try await douyin.fetchDetail(videoURL: url)
        }, onBrowserCookiesFailed: {
            Task { @MainActor in AppModel.shared.browserCookiesFailed = true }
        })
    }()

    private init() {
        #if DEBUG
        // UI tests run in a data folder of their own, never the real one.
        let env = ProcessInfo.processInfo.environment
        if let dir = env["VIDFLOW_DATA_DIR"] { AppPaths.dataDir = URL(fileURLWithPath: dir, isDirectory: true) }
        #endif
        SettingsStore.shared.load()
        var settings = SettingsStore.shared.current
        #if DEBUG
        if env["VIDFLOW_SKIP_FIRST_RUN"] == "1" { settings.firstRunCompleted = true }
        #endif
        self.settings = settings
        L.apply(language: settings.language)
        #if DEBUG
        if let language = env["VIDFLOW_LANGUAGE"] { L.apply(language: language) }
        #endif
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        tools = ToolManager(bundledHelpers: helpers)
        vault = CookieVault()
        downloads = DownloadManager()
        components = ComponentsModel(tools: tools)
        updates = UpdateModel()
    }

    /// Called once, when the app has finished launching.
    func start() {
        ProcessRunner.killOrphans()
        vault.closeSession() // Whatever the previous run left behind.
        applyTheme()
        downloads.loadPersisted()
        clipboard.update(watching: settings.watchClipboard)
        components.start()
        updates.start()
        NotificationService.shared.start()
        if !settings.firstRunCompleted { showFirstRun = true }
        Task { await checkConnectivity() }
        #if DEBUG
        DebugDriver.shared.start()
        #endif
    }

    func applyTheme() {
        NSApp.appearance = switch settings.theme {
        case "Light": NSAppearance(named: .aqua)
        case "Dark": NSAppearance(named: .darkAqua)
        default: nil
        }
    }

    func checkConnectivity() async {
        connectivityChecking = true
        let result = await Connectivity.check()
        connectivity = result
        connectivityChecking = false
        Log.info(result.reachable ? "YouTube reachable in \(Int(result.latency * 1000)) ms" : "YouTube unreachable: \(result.error ?? "")")
    }

    /// Brings the main window forward, whether or not it is open.
    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openMainWindowAction?()
    }

    @ObservationIgnored var openMainWindowAction: (() -> Void)?
    @ObservationIgnored var openSettingsAction: (() -> Void)?

    func openSettings(_ tab: SettingsTab) {
        settingsTab = tab
        NSApp.activate(ignoringOtherApps: true)
        openSettingsAction?()
    }

    /// Entry point for links from drag-and-drop, the Dock, notifications and the menu bar.
    func open(links text: String) {
        pendingLinks = text
        sidebar = .newDownload
        showMainWindow()
    }

    func signOut(_ platform: Platform) async {
        let cookies = await WebSession.removeCookies(for: platform)
        vault.store(cookies)
        accountsRevision += 1
    }

    func quitRelaunching() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        // A small delay lets this instance finish quitting first, so the two never run downloads at once.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", url.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}

extension Platform {
    var assetName: String { "platform-\(rawValue.lowercased())" }
}
