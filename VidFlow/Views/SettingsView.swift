import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import VidFlowCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The window fits the pane it shows; what a pane unfolds beyond that scrolls.
    private var paneHeight: CGFloat {
        switch model.settingsTab {
        case .general: 440
        case .downloads: 620
        case .network: 300
        case .updates: 500
        case .about: 500
        }
    }

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            GeneralPane().tabItem { Label(L.get("Settings_General"), systemImage: "gearshape") }.tag(SettingsTab.general)
            DownloadsPane().tabItem { Label(L.get("Settings_Downloads"), systemImage: "arrow.down.circle") }.tag(SettingsTab.downloads)
            NetworkPane().tabItem { Label(L.get("Settings_Network"), systemImage: "network") }.tag(SettingsTab.network)
            UpdatesPane().tabItem { Label(L.get("Settings_Updates"), systemImage: "arrow.triangle.2.circlepath") }.tag(SettingsTab.updates)
            AboutPane().tabItem { Label(L.get("Settings_About"), systemImage: "info.circle") }.tag(SettingsTab.about)
        }
        .frame(width: 540, height: paneHeight)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.settingsTab)
    }
}

/// A setting with its explanation one hover away, so the pane reads as a short list.
private struct Described<Content: View>: View {
    let description: String
    @ViewBuilder let content: Content

    var body: some View {
        content.help(description).accessibilityHint(description)
    }
}

private struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    @State private var loginItem = LoginItem.isOn
    @State private var loginStatus = LoginItem.status
    @State private var notificationsDenied = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker(L.get("Settings_Language"), selection: $model.settings.language) {
                    Text(L.get("Settings_LanguageSystem")).tag("")
                    Text("简体中文").tag("zh")
                    Text("English").tag("en")
                }
                if model.settings.language != model.launchLanguage {
                    HStack {
                        Text(L.get("Settings_RestartMessage")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(L.get("Settings_RestartNow")) { model.quitRelaunching() }
                    }
                }
                Picker(L.get("Settings_Theme"), selection: $model.settings.theme) {
                    Text(L.get("Settings_ThemeSystem")).tag("System")
                    Text(L.get("Settings_ThemeLight")).tag("Light")
                    Text(L.get("Settings_ThemeDark")).tag("Dark")
                }
            }
            Section {
                Described(description: L.get("Settings_MenuBarDescription")) {
                    Toggle(L.get("Settings_MenuBar"), isOn: $model.settings.showMenuBarItem)
                }
                Described(description: loginStatus == .requiresApproval ? L.get("Settings_LaunchAtLoginApproval") : L.get("Settings_LaunchAtLoginDescription")) {
                    Toggle(L.get("Settings_LaunchAtLogin"), isOn: Binding(get: { loginItem }, set: {
                        LoginItem.set($0)
                        loginItem = LoginItem.isOn
                        loginStatus = LoginItem.status
                    }))
                }
                if loginStatus == .requiresApproval {
                    Button(L.get("Settings_OpenLoginItems")) { SMAppService.openSystemSettingsLoginItems() }
                }
                Described(description: L.get("Settings_ClipboardDescription")) {
                    Toggle(L.get("Settings_Clipboard"), isOn: $model.settings.watchClipboard)
                }
            }
            Section(L.get("Settings_Background")) {
                Described(description: L.get("Settings_NotifyDescription")) {
                    Toggle(L.get("Settings_Notify"), isOn: $model.settings.notifyOnFinish)
                }
                Described(description: L.get("Settings_NotifyFailureDescription")) {
                    Toggle(L.get("Settings_NotifyFailure"), isOn: $model.settings.notifyOnFailure)
                }
                if notificationsDenied {
                    HStack {
                        Text(L.get("Settings_NotificationsDenied")).font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button(L.get("Settings_OpenNotifications")) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationsDenied = settings.authorizationStatus == .denied
        }
    }
}

private struct DownloadsPane: View {
    @Environment(AppModel.self) private var model
    @State private var other = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                LabeledContent(L.get("Settings_Folder")) {
                    HStack {
                        Text((model.settings.downloadFolder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button(L.get("Settings_Choose")) {
                            if let folder = Pickers.folder(startingAt: model.settings.downloadFolder) { model.settings.downloadFolder = folder }
                        }
                    }
                }
                Picker(L.get("Settings_Concurrency"), selection: $model.settings.maxConcurrent) {
                    ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                }
                Described(description: L.get("Settings_TemplatesDescription")) {
                    Picker(L.get("Settings_DefaultTemplate"), selection: Binding(
                        get: { model.templates.defaultTemplate(model.settings).id },
                        set: { model.settings.defaultTemplateId = $0 }
                    )) {
                        ForEach(model.templates.all) { Text($0.displayName).tag($0.id) }
                    }
                }
            }
            Section {
                Described(description: model.tools.path(.aria2) == nil ? L.get("Settings_MultiConnectionNeedsAria2") : L.get("Tools_Aria2Purpose")) {
                    Toggle(L.get("Settings_MultiConnection"), isOn: $model.settings.multiConnection)
                }
                Described(description: L.get("Settings_SpeedLimitDescription")) {
                    Toggle(L.get("Settings_Unlimited"), isOn: Binding(
                        get: { model.settings.speedLimitKBps > 0 },
                        set: { model.settings.speedLimitKBps = $0 ? max(1, model.settings.speedLimitValueKBps) : 0 }
                    ))
                }
                if model.settings.speedLimitKBps > 0 {
                    LabeledContent(L.get("Settings_SpeedMax")) {
                        HStack(spacing: 4) {
                            TextField(L.get("Settings_SpeedMax"), value: Binding(
                                get: { Double(model.settings.speedLimitKBps) / 1024 },
                                set: { value in
                                    let kbps = max(1, Int((value * 1024).rounded()))
                                    model.settings.speedLimitKBps = kbps
                                    model.settings.speedLimitValueKBps = kbps
                                }
                            ), format: .number.precision(.fractionLength(0...2)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                            Text("MB/s").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Described(description: L.get("Settings_H264Description")) {
                    Toggle(L.get("Settings_H264"), isOn: $model.settings.preferH264)
                }
            }
            Section {
                Described(description: L.get("Settings_MetadataDescription")) {
                    Toggle(L.get("Settings_Metadata"), isOn: $model.settings.embedMetadata)
                }
                Described(description: L.get("Settings_ChaptersDescription")) {
                    Toggle(L.get("Settings_Chapters"), isOn: $model.settings.embedChapters)
                }
                Described(description: L.get("Settings_SponsorBlockDescription")) {
                    Picker(L.get("Settings_SponsorBlock"), selection: $model.settings.sponsorBlock) {
                        Text(L.get("Settings_SponsorBlockOff")).tag(SponsorBlockModes.off)
                        Text(L.get("Settings_SponsorBlockMark")).tag(SponsorBlockModes.mark)
                        Text(L.get("Settings_SponsorBlockRemove")).tag(SponsorBlockModes.remove)
                    }
                }
            }
            Section {
                DisclosureGroup(L.get("Settings_SubLangs")) {
                let split = SubtitleLanguageSet.split(model.settings.subtitleLanguages)
                ForEach(SubtitleLanguageSet.common) { lang in
                    Toggle(lang.nativeName, isOn: Binding(get: { split.chosen.contains(lang.key) }, set: { on in
                        var chosen = split.chosen
                        if on { chosen.insert(lang.key) } else { chosen.remove(lang.key) }
                        model.settings.subtitleLanguages = SubtitleLanguageSet.join(chosen: chosen, other: other)
                    }))
                }
                Described(description: L.get("Settings_SubLangsOtherDescription")) {
                    TextField(L.get("Settings_SubLangsOther"), text: $other)
                        .onSubmit { saveOther() }
                        .onChange(of: other) { saveOther(tidy: false) }
                }
                Text({
                    let names = SubtitleLanguageSet.describe(model.settings.subtitleLanguages)
                    return names.isEmpty ? L.get("Settings_SubtitlesNone") : L.format("Settings_SubtitlesSummary", names)
                }())
                .font(.caption)
                .foregroundStyle(.secondary)
                }
                Described(description: L.get("Settings_DanmakuDescription")) {
                    Toggle(L.get("Settings_Danmaku"), isOn: $model.settings.saveDanmaku)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { other = SubtitleLanguageSet.split(model.settings.subtitleLanguages).other }
    }

    private func saveOther(tidy: Bool = true) {
        let chosen = SubtitleLanguageSet.split(model.settings.subtitleLanguages).chosen
        model.settings.subtitleLanguages = SubtitleLanguageSet.join(chosen: chosen, other: other)
        // Show the codes as saved (separators tidied, duplicates of ticked languages dropped).
        if tidy { other = SubtitleLanguageSet.split(model.settings.subtitleLanguages).other }
    }
}

private struct NetworkPane: View {
    @Environment(AppModel.self) private var model
    @State private var proxy = ""

    private static let browsers = ["safari", "chrome", "firefox", "edge", "brave", "chromium", "opera", "vivaldi"]

    var body: some View {
        @Bindable var model = model
        Form {
            Section(L.get("Settings_Proxy")) {
                Described(description: L.get("Settings_ProxyDescription")) {
                    TextField(L.get("Settings_Proxy"), text: $proxy, prompt: Text(L.get("Settings_ProxyPlaceholder")))
                        .autocorrectionDisabled()
                        .onSubmit(saveProxy)
                }
                HStack {
                    connectivityIcon
                    Text(connectivityText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(L.get("Settings_ConnectivityTest")) {
                        saveProxy()
                        Task { await model.checkConnectivity() }
                    }
                    .disabled(model.connectivityChecking)
                }
            }
            Section {
                DisclosureGroup(L.get("Settings_OtherCookies")) {
                Described(description: L.get("Settings_BrowserCookiesDescription")) {
                    Picker(L.get("Settings_BrowserCookies"), selection: $model.settings.cookiesBrowser) {
                        Text(L.get("Settings_BrowserNone")).tag("")
                        ForEach(Self.browsers, id: \.self) { Text(L.get("Browser_\($0.capitalized)")).tag($0) }
                    }
                }
                Described(description: L.get("Settings_CookieFileDescription")) {
                    LabeledContent(L.get("Settings_CookieFile")) {
                        HStack {
                            Text(model.settings.cookiesFile.isEmpty ? L.get("Settings_NoFile") : (model.settings.cookiesFile as NSString).lastPathComponent)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if !model.settings.cookiesFile.isEmpty {
                                Button(L.get("Common_Clear")) { model.settings.cookiesFile = "" }
                            }
                            Button(L.get("Settings_Choose")) {
                                if let file = Pickers.file() { model.settings.cookiesFile = file }
                            }
                        }
                    }
                }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { proxy = model.settings.proxy }
        .onDisappear(perform: saveProxy)
    }

    private func saveProxy() {
        let value = proxy.trimmingCharacters(in: .whitespaces)
        guard value != model.settings.proxy else { return }
        model.settings.proxy = value
        // A new proxy: does YouTube work with it?
        Task { await model.checkConnectivity() }
    }

    @ViewBuilder private var connectivityIcon: some View {
        if model.connectivityChecking {
            ProgressView().controlSize(.small)
        } else if let last = model.connectivity {
            Image(systemName: last.reachable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(last.reachable ? .green : .orange)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "network").foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }

    private var connectivityText: String {
        if model.connectivityChecking { return L.get("Settings_ConnectivityChecking") }
        guard let last = model.connectivity else { return L.get("Settings_ConnectivityIdle") }
        return last.reachable ? L.format("Settings_ConnectivityOk", Int(last.latency * 1000)) : L.get("Settings_ConnectivityFailed")
    }
}

struct AccountRows: View {
    @Environment(AppModel.self) private var model

    private func texts(_ p: Platform) -> (signedIn: String, signedOut: String) {
        switch p {
        case .bilibili: (L.get("Account_BiliIn"), L.get("Account_BiliOut"))
        case .douyin: (L.get("Account_DouyinIn"), L.get("Account_DouyinOut"))
        default: (L.get("Account_YtIn"), L.get("Account_YtOut"))
        }
    }

    var body: some View {
        let _ = model.accountsRevision
        ForEach(CookieVault.signInPlatforms) { p in
            let signedIn = model.vault.isLoggedIn(p)
            HStack(spacing: 10) {
                Image(p.assetName)
                    .resizable()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.displayName)
                    Text(signedIn ? texts(p).signedIn : texts(p).signedOut)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if signedIn {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel(L.get("Wizard_SignedIn"))
                    Button(L.get("Account_Logout")) { Task { await model.signOut(p) } }
                } else {
                    Button(L.get("Account_Login")) { Task { await LoginWindowController.show(p) } }
                }
            }
        }
    }
}

struct AccountsView: View {
    var body: some View {
        Form {
            Section {
                AccountRows()
            } footer: {
                Text(L.get("Accounts_Description")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: contentColumnWidth)
        .frame(maxWidth: .infinity)
        .navigationTitle(L.get("Nav_Accounts"))
    }
}

struct ComponentRow: View {
    let component: ComponentStatus
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(component.tool.rawValue)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if component.state == .installing {
                    ProgressView(value: component.progress ?? 0, total: 100).controlSize(.small)
                }
            }
            Spacer()
            trailing
        }
    }

    private var detail: String {
        let name = component.tool.rawValue
        let version = component.version ?? "?"
        switch component.state {
        case .missing: return L.get(component.tool.missingKey)
        case .systemCopy, .bundled, .upToDate: return L.format("Tools_Installed", L.get(component.tool.purposeKey), version)
        case .installing: return L.format("Wizard_Installing", name)
        case .checking: return L.get("Tools_Checking")
        case .checkFailed: return L.format("Tools_Installed", L.get(component.tool.purposeKey), version)
        case .updateAvailable: return "\(L.format("Tools_Installed", L.get(component.tool.purposeKey), version)) → \(component.latest ?? "")"
        }
    }

    @ViewBuilder private var trailing: some View {
        switch component.state {
        case .missing:
            Button(L.get("Tools_Install")) { install() }.disabled(busy)
        case .updateAvailable:
            Button(L.get("Tools_Update")) { install() }.disabled(busy)
        case .checking, .installing:
            ProgressView().controlSize(.small)
        case .upToDate, .systemCopy, .bundled, .checkFailed:
            EmptyView()
        }
    }

    private var busy: Bool { model.components.installing || model.components.checking }
    private func install() { Task { await model.components.install([component]) } }
}

private struct ComponentsSections: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let components = model.components
        let due = components.components.filter { $0.state == .missing || $0.state == .updateAvailable }
        Group {
            Section(L.get("Settings_Components")) {
                ForEach(components.components) { ComponentRow(component: $0) }
                HStack {
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if !due.isEmpty {
                        Button(L.get("Tools_UpdateAll")) { Task { await components.install(due) } }
                            .disabled(components.installing || components.checking)
                    }
                    Button(L.get("Settings_CheckUpdate")) { Task { await components.refresh(remote: true) } }
                        .disabled(components.installing || components.checking)
                }
                if let result = components.lastResult {
                    Label(result.message, systemImage: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(result.succeeded ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                }
                Described(description: L.get("Settings_AutoUpdateDescription")) {
                    Toggle(L.get("Settings_AutoUpdate"), isOn: $model.settings.autoUpdateComponents)
                }
                Button(L.get("About_RepairComponents")) { Task { await components.repair() } }
                    .disabled(components.installing || components.checking)
                    .help(L.get("About_RepairComponentsHelp"))
            }
        }
        .task { await components.refresh(remote: components.lastCheck == nil) }
    }

    private var summary: String {
        let c = model.components
        if let required = c.components.first(where: { $0.tool.required && $0.state == .missing }) {
            return L.format("Tools_MissingRequired", required.tool.rawValue)
        }
        if c.checking { return L.get("Tools_Checking") }
        let due = c.components.filter { $0.state == .missing || $0.state == .updateAvailable }.count
        if due > 0 { return L.format("Tools_ActionsNeeded", due) }
        if c.components.contains(where: { $0.state == .checkFailed }) { return L.get("Tools_CheckFailedSummary") }
        if let last = c.lastCheck { return L.format("Tools_LastChecked", last.formatted(date: .abbreviated, time: .shortened)) }
        return L.get("Tools_ManagedNote")
    }
}

private struct UpdatesPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let updates = model.updates
        Form {
            Section {
                Described(description: L.get("Settings_UpdateModeDescription")) {
                    Picker(L.get("Settings_UpdateMode"), selection: $model.settings.updateMode) {
                        Text(L.get("UpdateMode_Auto")).tag("auto")
                        Text(L.get("UpdateMode_Notify")).tag("notify")
                        Text(L.get("UpdateMode_Manual")).tag("manual")
                    }
                }
            }
            Section {
                status(updates)
                if updates.lastResult.outcome == .failed, let v = updates.lastResult.version {
                    Text(L.format("Update_RolledBack", v, UpdateModel.currentVersion)).font(.callout).foregroundStyle(.orange)
                }
            }
            if let m = updates.latest, updates.hasNewer, !m.notes.isEmpty {
                Section(L.get("Settings_ReleaseNotes")) {
                    Text(m.notes).font(.callout).textSelection(.enabled)
                }
            }
            ComponentsSections()
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func status(_ updates: UpdateModel) -> some View {
        let version = updates.latest?.version ?? ""
        switch updates.state {
        case .idle, .upToDate:
            HStack {
                Text(updates.state == .upToDate ? L.format("Update_UpToDate", UpdateModel.currentVersion) : L.format("Update_Current", UpdateModel.currentVersion))
                    .foregroundStyle(.secondary)
                Spacer()
                checkButton(updates)
            }
        case .checking:
            HStack {
                ProgressView().controlSize(.small)
                Text(L.get("Update_Checking")).foregroundStyle(.secondary)
            }
        case .available:
            HStack {
                Text(L.format("Update_Available", version, UpdateModel.currentVersion))
                Spacer()
                if updates.canSelfUpdate {
                    Button(L.get("Update_Download")) { Task { await updates.download() } }
                } else {
                    Button(L.get("Update_OpenReleases")) {
                        NSWorkspace.shared.open(URL(string: "https://github.com/Magicherry/VidFlow-for-Mac/releases/latest")!)
                    }
                }
            }
        case .downloading:
            VStack(alignment: .leading, spacing: 4) {
                Text(L.format("Update_Downloading", version, Int(updates.progress))).foregroundStyle(.secondary)
                ProgressView(value: updates.progress, total: 100)
            }
        case .ready:
            HStack {
                Text(L.format("Update_Ready", version))
                Spacer()
                Button(L.get("Update_InstallNow")) { Task { await updates.installNow() } }
                    .buttonStyle(.borderedProminent)
            }
        case .failed:
            HStack {
                Text(L.format("Update_Failed", updates.error ?? "")).foregroundStyle(.orange)
                Spacer()
                checkButton(updates)
            }
        }
    }

    private func checkButton(_ updates: UpdateModel) -> some View {
        Button(L.get("Settings_CheckUpdate")) { Task { await updates.check(userInitiated: true) } }
    }
}

private struct AboutPane: View {
    @Environment(AppModel.self) private var model

    private static let licenses: [(name: String, license: String, url: String, note: String?)] = [
        ("yt-dlp", "Unlicense", "https://github.com/yt-dlp/yt-dlp/blob/master/LICENSE", "Licenses_YtDlpNote"),
        ("FFmpeg", "GPL-3.0", "https://ffmpeg.org/legal.html", "Licenses_FfmpegNote"),
        ("Deno", "MIT", "https://github.com/denoland/deno/blob/main/LICENSE.md", "Licenses_YtDlpNote"),
        ("aria2", "GPL-2.0", "https://github.com/aria2/aria2/blob/master/COPYING", "Licenses_Aria2Note"),
    ]

    private func exportDiagnostics() async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "VidFlow-diagnostics.zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var tools: [(name: String, version: String?, path: String?)] = []
        for c in model.components.components {
            tools.append((c.tool.rawValue, await model.tools.installedVersion(c.tool), model.tools.path(c.tool)))
        }
        let report = Diagnostics.report(appVersion: UpdateModel.currentVersion, tools: tools)
        do {
            try await Diagnostics.export(to: url, report: report, settings: model.settings)
            Finder.reveal(url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                    Text("VidFlow").font(.title2.weight(.semibold))
                    Text(L.format("About_Version", UpdateModel.currentVersion)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(L.get("About_Description")).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Link(L.get("About_Website"), destination: URL(string: "https://github.com/Magicherry/VidFlow-for-Mac")!)
                        .font(.callout)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            } footer: {
                Text(L.get("About_Disclaimer")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L.get("About_Troubleshoot")) {
                Button(L.get("About_OpenLogs")) { Finder.reveal(AppPaths.logsDir) }
                Button(L.get("About_OpenData")) { Finder.reveal(AppPaths.dataDir) }
                Button(L.get("About_ExportDiagnostics")) { Task { await exportDiagnostics() } }
                    .help(L.get("About_ExportDiagnosticsHelp"))
                Button(L.get("About_RunWizard")) {
                    model.showFirstRun = true
                    model.showMainWindow()
                }
            }
            Section {
                DisclosureGroup(L.get("Licenses_Title")) {
                ForEach(Self.licenses, id: \.name) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(item.name)
                            Spacer()
                            Link(item.license, destination: URL(string: item.url)!)
                        }
                        if let note = item.note { Text(L.get(note)).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The first-launch sheet: components, where to save, and (optionally) accounts.
struct FirstRunView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                if step == 0 {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64).accessibilityHidden(true)
                } else {
                    Image(systemName: step == 1 ? "folder" : "person.crop.circle")
                        .font(.system(size: 40))
                        .foregroundStyle(.tint)
                        .frame(height: 64)
                        .accessibilityHidden(true)
                }
                Text(L.get(["Wizard_WelcomeTitle", "Wizard_FolderTitle", "Wizard_AccountsTitle"][step]))
                    .font(.title2.weight(.semibold))
                Text(L.get(["Wizard_WelcomeBody", "Wizard_FolderBody", "Wizard_AccountsBody"][step]))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 24)

            Form {
                switch step {
                case 0:
                    Section {
                        ForEach(model.components.components) { ComponentRow(component: $0) }
                    } footer: {
                        if let result = model.components.lastResult, !result.succeeded {
                            Text(result.message).font(.caption).foregroundStyle(.orange)
                        }
                    }
                case 1:
                    Section {
                        LabeledContent((model.settings.downloadFolder as NSString).abbreviatingWithTildeInPath) {
                            Button(L.get("Settings_Choose")) {
                                if let folder = Pickers.folder(startingAt: model.settings.downloadFolder) { model.settings.downloadFolder = folder }
                            }
                        }
                    }
                default:
                    Section {
                        AccountRows()
                    } footer: {
                        Text(L.get("Wizard_AccountsNote")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 240)

            HStack {
                if step == 0, !model.components.missing.isEmpty {
                    Button(L.get("Wizard_InstallAll")) { Task { await model.components.install(model.components.missing) } }
                        .disabled(model.components.installing || model.components.checking)
                }
                if step > 0 { Button(L.get("Wizard_Back")) { step -= 1 } }
                Spacer()
                if step < 2 { Button(L.get("Wizard_Skip")) { finish() } }
                Button(L.get(step == 2 ? "Wizard_Finish" : "Wizard_Next")) {
                    if step == 2 { finish() } else { step += 1 }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520)
    }

    private func finish() {
        model.settings.firstRunCompleted = true
        dismiss()
    }
}
