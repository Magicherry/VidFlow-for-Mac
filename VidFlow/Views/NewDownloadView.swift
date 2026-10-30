import SwiftUI
import VidFlowCore

struct NewDownloadView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var savingTemplate = false
    @State private var newTemplateName = ""
    @FocusState private var linkFocused: Bool

    var body: some View {
        @Bindable var composer = model.composer
        VStack(spacing: 0) {
            linkBar
            if let message = composer.message {
                MessageBanner(message: message, onLogin: composer.signIn) { composer.message = nil }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            } else if !model.components.hasYtDlp {
                toolsMissing
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                .id(pageKey)
        }
        .frame(maxWidth: contentColumnWidth, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: pageKey)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: composer.message)
        .overlay(alignment: .bottom) { toast }
        .toolbar {
            if hasResult {
                ToolbarItem(placement: .primaryAction) {
                    Button(composer.downloadTitle) { composer.requestDownload() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(composer.downloadCount == 0)
                }
            }
        }
        .navigationTitle(L.get("Nav_Home"))
        .inspector(isPresented: Binding(get: { model.showOptionsInspector }, set: { model.showOptionsInspector = $0 })) {
            OptionsInspector(savingTemplate: $savingTemplate, newTemplateName: $newTemplateName)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
        }
        .onAppear {
            composer.syncWithTemplates()
            consumePending()
            linkFocused = true
        }
        .onChange(of: model.pendingLinks) { consumePending() }
        .alert(L.get("Home_ConfirmManyTitle"), isPresented: Binding(get: { composer.confirmMany != nil }, set: { if !$0 { composer.confirmMany = nil } })) {
            Button(L.format("Download_Selected", composer.confirmMany ?? 0)) { composer.enqueue() }
            Button(L.get("Common_Cancel"), role: .cancel) {}
        } message: {
            Text(L.format("Home_ConfirmManyBody", composer.confirmMany ?? 0))
        }
        .alert(L.get("Home_DuplicateTitle"), isPresented: Binding(get: { composer.confirmDuplicates != nil }, set: { if !$0 { composer.confirmDuplicates = nil } })) {
            Button(L.get("Home_DownloadAgain")) { composer.resolveDuplicates(downloadAgain: true) }
            Button(L.get("Home_SkipDuplicates")) { composer.resolveDuplicates(downloadAgain: false) }
            Button(L.get("Common_Cancel"), role: .cancel) {}
        } message: {
            Text(L.format("Home_DuplicateBody", composer.confirmDuplicates?.count ?? 0))
        }
        .alert(L.get("Template_SaveAsTitle"), isPresented: $savingTemplate) {
            TextField(L.get("Template_Name"), text: $newTemplateName)
            Button(L.get("Common_Save")) {
                let name = newTemplateName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { composer.saveAsTemplate(name: name) }
            }
            Button(L.get("Common_Cancel"), role: .cancel) {}
        }
    }

    private var hasResult: Bool {
        switch model.composer.result {
        case .video, .playlist, .batch: true
        default: false
        }
    }

    /// Which of the page's states is showing, to fade between them.
    private var pageKey: Int {
        switch model.composer.result {
        case .empty: 0
        case .loading: 1
        case .video: 2
        case .playlist: 3
        case .batch: 4
        }
    }

    /// "Added", for a moment, without taking any room on the page.
    @ViewBuilder private var toast: some View {
        if let text = model.composer.toast {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
                Text(text).lineLimit(1)
                Button(L.get("Home_ViewDownloads")) {
                    model.composer.toast = nil
                    model.sidebar = .downloads(.all)
                }
                .buttonStyle(.link)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.bottom, 16)
            .padding(.horizontal, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: text) {
                try? await Task.sleep(for: .seconds(3.5))
                if !Task.isCancelled { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { model.composer.toast = nil } }
            }
        }
    }

    private func consumePending() {
        guard let text = model.pendingLinks else { return }
        model.pendingLinks = nil
        model.composer.load(text: text)
    }

    private var linkBar: some View {
        @Bindable var composer = model.composer
        return HStack(spacing: 8) {
            TextField(L.get("Home_UrlBoxName"), text: $composer.urlText, prompt: Text(L.get("Home_UrlPlaceholder")))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .focused($linkFocused)
                .accessibilityLabel(L.get("Home_UrlBoxName"))
                .onSubmit { composer.parse() }
            if !composer.urlText.isEmpty {
                Button { composer.clear() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .help(L.get("Common_Clear"))
                    .accessibilityLabel(L.get("Common_Clear"))
            }
            if composer.result == .loading {
                Button(L.get("Common_Cancel")) { composer.cancelParse() }
            } else if hasResult {
                Button(L.get("Home_Parse")) { composer.parse() }
            } else {
                // The one thing to do on this page until there's something to download.
                Button(L.get("Home_Parse")) { composer.parse() }
                    .buttonStyle(.borderedProminent)
                    .disabled(UrlTools.extractURLs(composer.urlText).isEmpty)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var toolsMissing: some View {
        MessageBanner(message: ComposerMessage(kind: .warning, title: L.get("Home_ToolsMissingTitle"), text: L.get("Home_ToolsMissingMessage"), openComponents: true))
    }

    @ViewBuilder private var content: some View {
        switch model.composer.result {
        case .empty: PlatformsList()
        case .loading: ProgressView(L.get("Home_Loading"))
        case .video(let v):
            Form {
                VideoPreview(video: v)
                QuickOptions()
            }
            .formStyle(.grouped)
        case .playlist(let p):
            Form {
                PlaylistPreview(playlist: p)
                QuickOptions()
            }
            .formStyle(.grouped)
        case .batch:
            Form {
                BatchPreview()
                QuickOptions()
            }
            .formStyle(.grouped)
        }
    }
}

/// What VidFlow can read: quiet, and out of the way.
private struct PlatformsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label(L.get("Home_DropHint"), systemImage: "arrow.down.circle")
        } description: {
            Text(L.get("Home_Subtitle"))
        } actions: {
            HStack(spacing: 12) {
                ForEach(Platform.supported) { p in
                    Image(p.assetName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .help(p.displayName)
                        .accessibilityLabel(p.displayName)
                }
            }
            if model.connectivity?.reachable == false {
                Button(L.get("Home_UnreachableTip")) { model.openSettings(.network) }
                    .buttonStyle(.link)
            }
        }
    }
}

private struct VideoPreview: View {
    let video: VideoInfo

    var body: some View {
        Section {
            // Side by side while the title has room to read; stacked when the options panel leaves too little.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    thumbnail.frame(width: 176)
                    details.frame(minWidth: 200, alignment: .leading)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 10) {
                    thumbnail
                    details
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var thumbnail: some View {
        RemoteImage(url: video.thumbnailURL, platform: video.platform)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .bottomTrailing) {
                if let d = video.duration, d > 0 {
                    Text(Format.duration(d))
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.white)
                        .padding(5)
                }
            }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(video.title)
                .font(.headline)
                .lineLimit(3)
                .textSelection(.enabled)
                .help(video.title)
            Text(([video.platform.displayName, video.uploader, Format.date(video.uploadDate)] as [String?]).compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !video.features.isEmpty {
                HStack(spacing: 4) {
                    ForEach(video.features, id: \.self) { f in
                        Text(MediaFeatures.label(f))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}

/// "All / None" beside a list's count, as a section header.
private struct SelectionHeader: View {
    let text: String
    let all: () -> Void
    let none: () -> Void

    var body: some View {
        HStack {
            Text(text)
            Spacer()
            Button(L.get("Playlist_SelectAll"), action: all).buttonStyle(.link).font(.callout)
            Button(L.get("Playlist_SelectNone"), action: none).buttonStyle(.link).font(.callout)
        }
    }
}

private struct PlaylistPreview: View {
    let playlist: PlaylistInfo
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var composer = model.composer
        Section {
            HStack(spacing: 14) {
                RemoteImage(url: playlist.thumbnailURL, platform: playlist.platform)
                    .frame(width: 112, height: 63)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(playlist.title).font(.headline).lineLimit(2).help(playlist.title)
                    Text(([L.get(playlist.platform == .bilibili ? "Playlist_KindParts" : "Playlist_KindPlaylist"), L.format("Playlist_Count", playlist.entries.count), playlist.uploader] as [String?]).compactMap { $0 }.joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        }
        Section {
            ForEach(playlist.entries) { e in
                Toggle(isOn: Binding(get: { composer.selectedEntries.contains(e.index) }, set: { on in
                    if on { composer.selectedEntries.insert(e.index) } else { composer.selectedEntries.remove(e.index) }
                })) {
                    HStack {
                        Text(e.title).lineLimit(1).help(e.title)
                        Spacer()
                        if let d = e.duration, d > 0 {
                            Text(Format.duration(d)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
            }
        } header: {
            SelectionHeader(text: L.format("Playlist_Selected", composer.selectedEntries.count, playlist.entries.count),
                            all: { composer.selectedEntries = Set(playlist.entries.map(\.index)) },
                            none: { composer.selectedEntries = [] })
        }
    }
}

private struct BatchPreview: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let composer = model.composer
        let done = composer.batch.filter { !$0.isLoading }.count
        let failed = composer.batch.filter(\.failed).count
        Section {
            ForEach(composer.batch) { BatchRow(entry: $0) }
        } header: {
            SelectionHeader(text: failed > 0 ? L.format("Batch_StatusFailed", done, composer.batch.count, failed) : L.format("Batch_Status", done, composer.batch.count),
                            all: {
                                composer.batchSelectionTouched = true
                                composer.batch.forEach { $0.selected = $0.info != nil }
                            },
                            none: {
                                composer.batchSelectionTouched = true
                                composer.batch.forEach { $0.selected = false }
                            })
        }
    }
}

private struct BatchRow: View {
    @Bindable var entry: BatchEntry
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { entry.selected }, set: {
                model.composer.batchSelectionTouched = true
                entry.selected = $0
            }))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(entry.info == nil)
            .accessibilityLabel(entry.title)
            RemoteImage(url: entry.info?.thumbnailURL, platform: entry.info?.platform)
                .frame(width: 64, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).lineLimit(1).help(entry.title)
                Text(entry.meta)
                    .font(.caption)
                    .foregroundStyle(entry.failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .help(entry.meta)
            }
            Spacer(minLength: 0)
            if entry.isLoading { ProgressView().controlSize(.small) }
        }
    }
}

/// The two choices nearly every download needs; the rest are one click further.
private struct QuickOptions: View {
    @Environment(AppModel.self) private var model

    private var destination: String {
        let folder = model.composer.options.folderTemplate
        let base = (model.settings.downloadFolder as NSString).abbreviatingWithTildeInPath
        return folder.isEmpty ? base : (base as NSString).appendingPathComponent(folder)
    }

    var body: some View {
        @Bindable var composer = model.composer
        let sections = OptionsSections(options: $composer.options, video: composer.video, showNaming: false)
        Section {
            LabeledContent(L.get("Options_Mode")) {
                Picker(L.get("Options_Mode"), selection: sections.mode) {
                    Text(L.get("Mode_Video")).tag("video")
                    Text(L.get("Mode_Audio")).tag("audio")
                    Text(L.get("Mode_Cover")).tag("cover")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if composer.options.mode == "video" {
                Picker(L.get("Options_Quality"), selection: sections.quality) {
                    ForEach(sections.qualityChoices, id: \.tag) { Text($0.text).tag($0.tag) }
                }
            }
            LabeledContent(L.get("Options_Folder")) {
                HStack(spacing: 8) {
                    Text(destination)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(destination)
                    Button(L.get("Settings_Choose")) {
                        if let folder = Pickers.folder(startingAt: model.settings.downloadFolder) { model.settings.downloadFolder = folder }
                    }
                }
            }
        } footer: {
            HStack {
                Spacer()
                Button(L.get("Home_MoreOptions")) { model.showOptionsInspector.toggle() }
                    .buttonStyle(.link)
            }
        }
    }
}

/// The task's options: the template it starts from, and the changes made for this download only.
private struct OptionsInspector: View {
    @Binding var savingTemplate: Bool
    @Binding var newTemplateName: String
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var composer = model.composer
        Form {
            Section(L.get("Template_Header")) {
                Picker(L.get("Template_Header"), selection: Binding(get: { composer.template.id }, set: { id in
                    if let t = model.templates.find(id) { composer.use(t) }
                })) {
                    ForEach(model.templates.all) { t in
                        Text(t.id == model.templates.defaultTemplate(model.settings).id ? L.format("Template_DefaultSuffix", t.displayName) : t.displayName)
                            .tag(t.id)
                    }
                }
                .labelsHidden()
                if composer.isModified {
                    HStack {
                        Button(L.get("Template_Reset")) { composer.use(composer.template) }
                        Button(L.get("Template_SaveAs")) {
                            newTemplateName = model.templates.uniqueName(L.get("Template_NewName"))
                            savingTemplate = true
                        }
                    }
                }
            }
            OptionsSections(options: $composer.options, video: composer.video, showNaming: false)
        }
        .formStyle(.grouped)
    }
}
