import AppKit
import SwiftUI
import VidFlowCore

@main
struct VidFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("VidFlow", id: "main") {
            MainView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 1080, height: 700)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra("VidFlow", systemImage: "arrow.down.circle", isInserted: Binding(
            get: { model.settings.showMenuBarItem },
            // SwiftUI writes this back as it updates; only a real change may touch the observed settings.
            set: { if model.settings.showMenuBarItem != $0 { model.settings.showMenuBarItem = $0 } }
        )) {
            MenuBarContent()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        AppModel.shared.start()
    }

    /// Closing the window leaves downloads running, as on any Mac; the Dock icon brings it back.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows visible: Bool) -> Bool {
        if !visible { AppModel.shared.showMainWindow() }
        return true
    }

    /// A link dropped on the Dock icon, or a vidflow:// address.
    func application(_: NSApplication, open urls: [URL]) {
        let links = urls.compactMap { url -> String? in
            if url.scheme == "vidflow" {
                return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "url" }?.value
            }
            return url.isFileURL ? (try? String(contentsOf: url, encoding: .utf8)) : url.absoluteString
        }
        if !links.isEmpty { AppModel.shared.open(links: links.joined(separator: " ")) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        let running = model.downloads.runningCount
        if running > 0, !model.updates.isInstallingNow {
            let alert = NSAlert()
            alert.messageText = L.get("Quit_ActiveTitle")
            alert.informativeText = L.format("Quit_ActiveBody", running)
            alert.addButton(withTitle: L.get("Quit_Quit"))
            alert.addButton(withTitle: L.get("Common_Cancel"))
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        return .terminateNow
    }

    func applicationWillTerminate(_: Notification) {
        let model = AppModel.shared
        model.isTerminating = true
        model.downloads.shutdown()
        model.updates.installOnQuit()
        ProcessRunner.stopAll()
        ProcessRunner.waitForAllToExit(timeout: 3)
        model.vault.closeSession()
    }
}

/// Holds the SwiftUI actions that can only be read from inside a view, for the code outside views that needs them.
struct ActionBridge: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.task {
            model.openMainWindowAction = { [openWindow] in openWindow(id: "main") }
            model.openSettingsAction = { [openSettings] in openSettings() }
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L.format("Menu_About")) { model.openSettings(.about) }
        }
        CommandGroup(after: .appInfo) {
            Button(L.get("Settings_CheckUpdate")) {
                model.openSettings(.updates)
                Task { await model.updates.check(userInitiated: true) }
            }
        }
        CommandGroup(replacing: .newItem) {
            Button(L.get("Menu_NewDownload")) {
                model.sidebar = .newDownload
                model.showMainWindow()
            }
            .keyboardShortcut("n")
            Button(L.get("Menu_PasteLink")) { model.pasteLink() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Divider()
            Button(L.get("Menu_DownloadsFolder")) {
                try? AppPaths.ensureDirectory(URL(fileURLWithPath: model.settings.downloadFolder))
                NSWorkspace.shared.open(URL(fileURLWithPath: model.settings.downloadFolder))
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(after: .toolbar) {
            Button(L.get("Menu_ToggleInspector")) { model.toggleInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(model.sidebar == .templates || model.sidebar == .accounts)
            Divider()
            Button(L.get("Nav_Home")) { model.sidebar = .newDownload }.keyboardShortcut("1")
            Button(L.get("Nav_Downloads")) { model.sidebar = .downloads(.all) }.keyboardShortcut("2")
            Button(L.get("Nav_Templates")) { model.sidebar = .templates }.keyboardShortcut("3")
            Button(L.get("Nav_Accounts")) { model.sidebar = .accounts }.keyboardShortcut("4")
        }
        CommandMenu(L.get("Menu_Downloads")) {
            Button(L.get("Menu_PauseAll")) { model.downloads.pauseAll() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(!model.downloads.canPauseAny)
            Button(L.get("Menu_ResumeAll")) { model.downloads.resumeAll() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!model.downloads.canResumeAny)
            Divider()
            Button(L.get("Menu_ClearFinished")) { model.downloads.clearFinished() }
                .disabled(!model.downloads.canClearFinished)
        }
        CommandGroup(replacing: .help) {
            Button(L.get("Menu_Help")) {
                NSWorkspace.shared.open(URL(string: "https://github.com/Magicherry/VidFlow-for-Mac#readme")!)
            }
        }
    }
}

extension AppModel {
    /// The current page's trailing panel.
    func toggleInspector() {
        switch sidebar {
        case .newDownload: showOptionsInspector.toggle()
        case .downloads: showDownloadInspector.toggle()
        case .templates, .accounts: break
        }
    }

    /// "Download copied link": whatever links are on the clipboard go to the New Download page.
    func pasteLink() {
        let text = NSPasteboard.general.string(forType: .string)
        if UrlTools.extractURLs(text).isEmpty {
            sidebar = .newDownload
            showMainWindow()
        } else if let text {
            open(links: text)
        }
    }
}

/// The status item's menu.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text(summary)
        Divider()
        Button(L.get("Menu_ShowVidFlow")) { model.showMainWindow() }
        Button(L.get("Menu_PasteLink")) { model.pasteLink() }
        Divider()
        Button(L.get("Menu_PauseAll")) { model.downloads.pauseAll() }.disabled(!model.downloads.canPauseAny)
        Button(L.get("Menu_ResumeAll")) { model.downloads.resumeAll() }.disabled(!model.downloads.canResumeAny)
        Divider()
        Button(L.get("Nav_Settings") + "…") { model.openSettings(.general) }
        Button(L.get("Tray_Exit")) { NSApp.terminate(nil) }
    }

    private var summary: String {
        let active = model.downloads.activeCount
        return active == 0 ? L.get("Tray_Idle") : L.format("Tray_Tooltip", active, Int(model.downloads.overallProgress))
    }
}
