import SwiftUI
import VidFlowCore

struct NewDownloadView: View {
    @Environment(AppModel.self) private var model
    @State private var savingTemplate = false
    @State private var newTemplateName = ""
    @FocusState private var linkFocused: Bool

    var body: some View {
        @Bindable var composer = model.composer
        VStack(spacing: 0) {
            linkBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let message = composer.message {
                        MessageBanner(message: message, onLogin: composer.signIn) { composer.message = nil }
                    }
                    if !model.components.hasYtDlp, composer.message == nil { toolsMissing }
                    content
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if hasResult { actionBar }
        }
        .navigationTitle(L.get("Nav_Home"))
        .inspector(isPresented: Binding(get: { model.showOptionsInspector }, set: { model.showOptionsInspector = $0 })) {
            OptionsInspector(savingTemplate: $savingTemplate, newTemplateName: $newTemplateName)
                .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
        .onAppear {
            composer.prefillFromClipboard()
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

    private func consumePending() {
        guard let text = model.pendingLinks else { return }
        model.pendingLinks = nil
        model.composer.load(text: text)
    }

    private var linkBar: some View {
        @Bindable var composer = model.composer
        return HStack(spacing: 8) {
            TextField(L.get("Home_UrlPlaceholder"), text: $composer.urlText)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($linkFocused)
                .accessibilityLabel(L.get("Home_UrlBoxName"))
                .onSubmit { composer.parse() }
            if !composer.urlText.isEmpty {
                Button { composer.clear() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(L.get("Common_Clear"))
            }
            if composer.result == .loading {
                Button(L.get("Common_Cancel")) { composer.cancelParse() }
            } else {
                Button(L.get("Home_Parse")) { composer.parse() }
                    .disabled(UrlTools.extractURLs(composer.urlText).isEmpty)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var toolsMissing: some View {
        MessageBanner(message: ComposerMessage(kind: .warning, title: L.get("Home_ToolsMissingTitle"), text: L.get("Home_ToolsMissingMessage"), openComponents: true))
    }

    @ViewBuilder private var content: some View {
        switch model.composer.result {
        case .empty: PlatformsList()
        case .loading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(L.get("Home_Loading")).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 160)
        case .video(let v):
            VideoPreview(video: v)
            QuickOptions()
        case .playlist(let p):
            PlaylistPreview(playlist: p)
            QuickOptions()
        case .batch:
            BatchPreview()
            QuickOptions()
        }
    }

    private var actionBar: some View {
        @Bindable var composer = model.composer
        return HStack(spacing: 10) {
            Button {
                if let folder = Pickers.folder(startingAt: model.settings.downloadFolder) { model.settings.downloadFolder = folder }
            } label: {
                Label(destination, systemImage: "folder").lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(L.get("Options_Change"))
            Spacer(minLength: 12)
            Button(composer.downloadTitle) { composer.requestDownload() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(composer.downloadCount == 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var destination: String {
        let folder = model.composer.options.folderTemplate
        let base = (model.settings.downloadFolder as NSString).abbreviatingWithTildeInPath
        return folder.isEmpty ? base : (base as NSString).appendingPathComponent(folder)
    }
}

/// What VidFlow can read: quiet, and out of the way.
private struct PlatformsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.circle").font(.system(size: 44, weight: .light)).foregroundStyle(.tertiary).accessibilityHidden(true)
            Text(L.get("Home_DropHint")).font(.title3).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ForEach(Platform.supported) { p in
                    Image(p.assetName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .help(p.displayName)
                        .accessibilityLabel(p.displayName)
                }
            }
            if model.connectivity?.reachable == false {
                Button(L.get("Home_UnreachableTip")) { model.openSettings(.network) }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}

private struct VideoPreview: View {
    let video: VideoInfo

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            thumbnail.frame(width: 240)
            details
            Spacer(minLength: 0)
        }
    }

    private var thumbnail: some View {
        RemoteImage(url: video.thumbnailURL)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .bottomTrailing) {
                if let d = video.duration, d > 0 {
                    Text(Format.duration(d))
                        .font(.caption.monospacedDigit().weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(video.title)
                .font(.title3.weight(.semibold))
                .lineLimit(4)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Image(video.platform.assetName)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .accessibilityHidden(true)
                Text(video.platform.displayName)
            }
            .foregroundStyle(.secondary)
            let meta = [video.uploader, Format.date(video.uploadDate)].compactMap { $0 }.filter { !$0.isEmpty }
            if !meta.isEmpty {
                Text(meta.joined(separator: " · ")).foregroundStyle(.secondary).lineLimit(1)
            }
            if !video.features.isEmpty {
                HStack(spacing: 4) {
                    ForEach(video.features, id: \.self) { f in
                        Text(MediaFeatures.label(f))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.tint))
                            .foregroundStyle(.tint)
                    }
                }
            }
        }
    }
}

private struct PlaylistPreview: View {
    let playlist: PlaylistInfo
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var composer = model.composer
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                RemoteImage(url: playlist.thumbnailURL)
                    .frame(width: 140, height: 79)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.get(playlist.platform == .bilibili ? "Playlist_KindParts" : "Playlist_KindPlaylist"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(playlist.title).font(.title3.weight(.semibold)).lineLimit(2)
                    Text([L.format("Playlist_Count", playlist.entries.count), playlist.uploader].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Text(L.format("Playlist_Selected", composer.selectedEntries.count, playlist.entries.count)).foregroundStyle(.secondary)
                Spacer()
                Button(L.get("Playlist_SelectAll")) { composer.selectedEntries = Set(playlist.entries.map(\.index)) }
                Button(L.get("Playlist_SelectNone")) { composer.selectedEntries = [] }
            }
            GroupBox {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(playlist.entries) { e in
                        Toggle(isOn: Binding(get: { composer.selectedEntries.contains(e.index) }, set: { on in
                            if on { composer.selectedEntries.insert(e.index) } else { composer.selectedEntries.remove(e.index) }
                        })) {
                            HStack {
                                Text(e.title).lineLimit(1)
                                Spacer()
                                if let d = e.duration, d > 0 {
                                    Text(Format.duration(d)).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 4)
                    }
                }
            }
        }
    }
}

private struct BatchPreview: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let composer = model.composer
        let done = composer.batch.filter { !$0.isLoading }.count
        let failed = composer.batch.filter(\.failed).count
        VStack(alignment: .leading, spacing: 12) {
            Text(L.format("Batch_Title", composer.batch.count)).font(.title3.weight(.semibold))
            if done < composer.batch.count {
                ProgressView(value: Double(done), total: Double(max(1, composer.batch.count)))
            }
            HStack {
                Text(failed > 0 ? L.format("Batch_StatusFailed", done, composer.batch.count, failed) : L.format("Batch_Status", done, composer.batch.count))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L.get("Playlist_SelectAll")) {
                    composer.batchSelectionTouched = true
                    composer.batch.forEach { $0.selected = $0.info != nil }
                }
                Button(L.get("Playlist_SelectNone")) {
                    composer.batchSelectionTouched = true
                    composer.batch.forEach { $0.selected = false }
                }
            }
            GroupBox {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(composer.batch) { BatchRow(entry: $0) }
                }
            }
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
            RemoteImage(url: entry.info?.thumbnailURL)
                .frame(width: 64, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).lineLimit(1)
                Text(entry.meta)
                    .font(.caption)
                    .foregroundStyle(entry.failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .help(entry.meta)
            }
            Spacer(minLength: 0)
            if entry.isLoading { ProgressView().controlSize(.small) }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
    }
}

/// The two choices nearly every download needs; the rest are one click further.
private struct QuickOptions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var composer = model.composer
        let sections = OptionsSections(options: $composer.options, video: composer.video, showNaming: false)
        HStack(spacing: 12) {
            Picker(L.get("Options_Mode"), selection: sections.mode) {
                Text(L.get("Mode_Video")).tag("video")
                Text(L.get("Mode_Audio")).tag("audio")
                Text(L.get("Mode_Cover")).tag("cover")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if composer.options.mode == "video" {
                Picker(L.get("Options_Quality"), selection: sections.quality) {
                    ForEach(sections.qualityChoices, id: \.tag) { Text($0.text).tag($0.tag) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Button(L.get("Home_MoreOptions")) { model.showOptionsInspector.toggle() }
                .buttonStyle(.link)
            Spacer(minLength: 0)
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
