import SwiftUI
import VidFlowCore

struct DownloadsView: View {
    let status: DownloadStatusFilter
    @Environment(AppModel.self) private var model
    @State private var selection = Set<UUID>()
    @State private var platform: Platform?
    @State private var query = ""
    @AppStorage("downloadThumbnailSize") private var thumbnailSize = ThumbnailSize.medium

    private var downloads: DownloadManager { model.downloads }

    private var filter: DownloadFilter { DownloadFilter(status: status, platform: platform, query: query) }

    private var shown: [DownloadItem] {
        let filter = self.filter
        // The list is kept newest first.
        return downloads.items.filter { filter.matches(state: $0.state, title: $0.title, url: $0.request.url, platform: $0.platform) }
    }

    private var selectedItems: [DownloadItem] { downloads.items.filter { selection.contains($0.id) } }

    var body: some View {
        let rows = shown
        Group {
            if rows.isEmpty {
                let nothing = downloads.items.isEmpty
                ContentUnavailableView(L.get(nothing ? "Downloads_EmptyTitle" : "Downloads_NoMatchTitle"),
                                       systemImage: nothing ? "arrow.down.circle" : "magnifyingglass",
                                       description: Text(L.get(nothing ? "Downloads_EmptyBody" : "Downloads_NoMatchBody")))
            } else {
                list(rows)
            }
        }
        .navigationTitle(L.get("Nav_Downloads"))
        .navigationSubtitle(subtitle)
        .searchable(text: $query, placement: .toolbar, prompt: L.get("Downloads_Search"))
        .inspector(isPresented: Binding(get: { model.showDownloadInspector }, set: { model.showDownloadInspector = $0 })) {
            DownloadInspector(items: selectedItems)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
        }
        .toolbar { toolbar }
    }

    private var subtitle: String {
        let active = downloads.activeCount
        return active > 0 ? L.format("Tray_Tooltip", active, Int(downloads.overallProgress)) : ""
    }

    private func list(_ rows: [DownloadItem]) -> some View {
        List(selection: $selection) {
            if status == .all {
                section(.active, rows)
                section(.failed, rows)
                section(.completed, rows)
            } else {
                ForEach(rows) { DownloadRow(item: $0, thumbnailWidth: thumbnailSize.width) }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: UUID.self) { ids in
            RowMenu(items: downloads.items.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            for item in downloads.items where ids.contains(item.id) { open(item) }
        }
        .onDeleteCommand {
            let gone = selectedItems.filter(\.canRemove)
            gone.forEach(downloads.remove)
            selection.subtract(gone.map(\.id))
        }
        .onKeyPress(.space) {
            let items = selectedItems
            guard !items.isEmpty else { return .ignored }
            for item in items {
                if item.canPause { downloads.pause(item) } else if item.canResume { downloads.resume(item) }
            }
            return .handled
        }
    }

    /// One status group, under a heading with its count; nothing when it's empty.
    @ViewBuilder private func section(_ group: DownloadStatusFilter, _ rows: [DownloadItem]) -> some View {
        let members = rows.filter { DownloadFilter.group(of: $0.state) == group }
        if !members.isEmpty {
            Section {
                ForEach(members) { DownloadRow(item: $0, thumbnailWidth: thumbnailSize.width) }
            } header: {
                Text("\(L.get("Downloads_Filter\(group.rawValue)")) \(members.count)")
            }
        }
    }

    private func open(_ item: DownloadItem) {
        if let file = item.existingFile { NSWorkspace.shared.open(file) } else if item.state == .completed { Finder.reveal(item.folder) }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if downloads.canPauseAny {
                Button(L.get("Downloads_PauseAll"), systemImage: "pause") { downloads.pauseAll() }
                    .help(L.get("Downloads_PauseAll"))
            } else if downloads.canResumeAny {
                Button(L.get("Downloads_ResumeAll"), systemImage: "play") { downloads.resumeAll() }
                    .help(L.get("Downloads_ResumeAll"))
            }
            Menu {
                Picker(L.get("Downloads_Status"), selection: Binding(get: { status }, set: { model.sidebar = .downloads($0) })) {
                    ForEach(DownloadStatusFilter.allCases, id: \.self) { f in
                        Text("\(L.get("Downloads_Filter\(f.rawValue)")) (\(downloads.count(f)))").tag(f)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                Button(L.get("Downloads_ClearFinished")) { downloads.clearFinished() }
                    .disabled(!downloads.canClearFinished)
            } label: {
                Label(L.get("Downloads_Status"), systemImage: status == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .help(L.get("Downloads_Status"))
            Menu {
                Picker(L.get("Downloads_Platform"), selection: $platform) {
                    Text(L.get("Downloads_AllPlatforms")).tag(Platform?.none)
                    ForEach(Platform.supported) { Text($0.displayName).tag(Platform?.some($0)) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label(L.get("Downloads_Platform"), systemImage: platform == nil ? "square.grid.2x2" : "square.grid.2x2.fill")
            }
            .help(L.get("Downloads_Platform"))
            Menu {
                Picker(L.get("Downloads_ThumbnailSize"), selection: $thumbnailSize) {
                    Text(L.get("Downloads_ThumbnailSmall")).tag(ThumbnailSize.small)
                    Text(L.get("Downloads_ThumbnailMedium")).tag(ThumbnailSize.medium)
                    Text(L.get("Downloads_ThumbnailLarge")).tag(ThumbnailSize.large)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label(L.get("Downloads_ThumbnailSize"), systemImage: "photo")
            }
            .help(L.get("Downloads_ThumbnailSize"))
        }
    }
}

extension DownloadItem {
    /// Speed and time left, while there are any.
    var liveFigures: String? {
        var parts: [String] = []
        if speed > 0 { parts.append("\(Format.bytes(speed))/s") }
        if eta > 0 { parts.append(L.format("Status_Remaining", Format.duration(eta))) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var addedAt: Date { createdAt }
    var stateLabel: String {
        switch state {
        case .queued: L.get("Status_Queued")
        case .downloading: L.get("Status_Downloading")
        case .processing: L.get("Status_Processing")
        case .completed: L.get("Status_Completed")
        case .failed: L.get("Status_Failed")
        case .canceled: L.get("Status_Canceled")
        case .paused: L.get("Status_Paused")
        }
    }
}

/// How big the list's thumbnails are; 16:9, by width.
enum ThumbnailSize: String {
    case small, medium, large

    var width: CGFloat {
        switch self {
        case .small: 56
        case .medium: 96
        case .large: 160
        }
    }
}

/// A download: its picture, its name, and below that whatever is true of it now, with the likely action at the end.
private struct DownloadRow: View {
    let item: DownloadItem
    let thumbnailWidth: CGFloat
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: item.thumbnailURL, platform: item.platform)
                .frame(width: thumbnailWidth, height: thumbnailWidth * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: thumbnailWidth > 100 ? 10 : 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).lineLimit(1).help(item.title)
                details
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.stateLabel)")
        .accessibilityValue(item.isActive ? "\(Int(item.progress))%" : "")
    }

    @ViewBuilder private var details: some View {
        switch item.state {
        case .downloading, .paused:
            ProgressView(value: min(item.progress, 100), total: 100)
                .controlSize(.small)
                .tint(item.state == .paused ? Color.gray : Color.accentColor)
            HStack(spacing: 8) {
                Text(item.statusText).lineLimit(1).help(item.statusText)
                Spacer(minLength: 8)
                if let figures = item.liveFigures { Text(figures).monospacedDigit().lineLimit(1) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .processing:
            ProgressView().progressViewStyle(.linear).controlSize(.small)
            Text(item.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        case .failed:
            Text(item.statusText).font(.caption).foregroundStyle(.red).lineLimit(1).help(item.statusText)
        case .queued, .canceled:
            Text(item.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        case .completed:
            if item.fileMissing {
                Label(L.get("Status_FileMissing"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("\(item.label) · \(item.addedAt.formatted(.dateTime.month().day().hour().minute()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(item.label)
            }
        }
    }

    /// The most likely thing to do with this row, as in Safari's download list.
    @ViewBuilder private var actions: some View {
        let downloads = model.downloads
        HStack(spacing: 10) {
            if item.canPause {
                actionButton("Action_Pause", "pause.fill") { downloads.pause(item) }
            } else if item.canResume {
                actionButton("Action_Resume", "play.fill") { downloads.resume(item) }
            } else if item.canRetry {
                actionButton(item.state == .completed ? "Action_Redownload" : "Action_Retry", "arrow.clockwise") { downloads.retry(item) }
            } else if item.state == .completed {
                if item.filePath != nil {
                    // A cover is a picture: it opens rather than plays.
                    actionButton(item.request.isCover ? "Menu_OpenFile" : "Action_Play", item.request.isCover ? "photo" : "play.circle.fill") {
                        if let file = item.existingFile { NSWorkspace.shared.open(file) }
                    }
                }
                actionButton("Menu_ShowInFinder", "magnifyingglass") { Finder.reveal(item.existingFile ?? item.folder) }
            }
        }
    }

    private func actionButton(_ key: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(L.get(key))
            .accessibilityLabel(L.get(key))
    }
}

/// Actions on the selected rows, for the context menu and the inspector.
private struct RowMenu: View {
    let items: [DownloadItem]
    @Environment(AppModel.self) private var model

    var body: some View {
        let downloads = model.downloads
        if items.contains(where: { $0.existingFile != nil }) {
            Button(L.get("Menu_OpenFile")) { items.compactMap(\.existingFile).forEach { NSWorkspace.shared.open($0) } }
        }
        if items.count == 1 {
            Button(L.get("Downloads_Inspector")) { model.showDownloadInspector = true }
        }
        if !items.isEmpty {
            Button(L.get("Menu_ShowInFinder")) { items.forEach { Finder.reveal($0.existingFile ?? $0.folder) } }
        }
        Divider()
        if items.contains(where: \.canPrioritize) {
            Button(L.get("Action_Prioritize")) { items.forEach(downloads.prioritize) }
        }
        if items.contains(where: \.canPause) {
            Button(L.get("Action_Pause")) { items.forEach(downloads.pause) }
        }
        if items.contains(where: \.canResume) {
            Button(L.get("Action_Resume")) { items.forEach(downloads.resume) }
        }
        if items.contains(where: \.canRetry) {
            Button(L.get(items.allSatisfy { $0.state == .completed } ? "Action_Redownload" : "Action_Retry")) { items.forEach(downloads.retry) }
        }
        if items.contains(where: \.canCancel) {
            Button(L.get("Downloads_Cancel")) { items.filter(\.canCancel).forEach(downloads.cancel) }
        }
        Divider()
        if !items.isEmpty {
            Button(L.get("Downloads_CopyLink")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(items.map(\.request.url).joined(separator: "\n"), forType: .string)
            }
        }
        if let failed = items.first(where: { $0.errorDetail != nil }) {
            Button(L.get("Action_CopyError")) { copyError(failed) }
        }
        if items.contains(where: \.canRemove) {
            Divider()
            Button(L.get("Action_Remove")) { items.filter(\.canRemove).forEach(downloads.remove) }
        }
    }
}

private func copyError(_ item: DownloadItem) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(Redact.text("\(item.title)\n\(item.request.url)\n\n\(item.statusText)\n\n\(item.errorDetail ?? "")"), forType: .string)
}

private struct DownloadInspector: View {
    let items: [DownloadItem]
    @Environment(AppModel.self) private var model

    var body: some View {
        if items.count == 1, let item = items.first {
            Form {
                Section {
                    RemoteImage(url: item.thumbnailURL, platform: item.platform)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Text(item.title).fontWeight(.semibold).textSelection(.enabled)
                }
                Section {
                    LabeledContent(L.get("Downloads_Status"), value: item.stateLabel)
                    if item.isActive || item.state == .paused {
                        LabeledContent(L.get("Downloads_Progress"), value: String(format: "%.1f%%", item.progress))
                    }
                    if item.totalBytes > 0, item.isRunning {
                        LabeledContent(L.get("Downloads_Size"), value: "\(Format.bytes(Double(item.downloadedBytes))) / \(Format.bytes(Double(item.totalBytes)))")
                    }
                    if item.speed > 0 { LabeledContent(L.get("Downloads_Speed"), value: "\(Format.bytes(item.speed))/s") }
                    if item.eta > 0 { LabeledContent(L.get("Downloads_Remaining"), value: Format.duration(item.eta)) }
                    LabeledContent(L.get("Downloads_Options"), value: DownloadLabels.optionsLabel(item.request))
                    LabeledContent(L.get("Downloads_Added"), value: item.addedAt.formatted(date: .abbreviated, time: .shortened))
                }
                Section {
                    LabeledContent(L.get("Downloads_Source")) {
                        Text(item.request.url).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                    }
                    if let file = item.filePath {
                        LabeledContent(L.get("Downloads_File")) {
                            Text((file as NSString).abbreviatingWithTildeInPath).lineLimit(4).truncationMode(.middle).textSelection(.enabled)
                        }
                    } else {
                        LabeledContent(L.get("Downloads_Folder")) {
                            Text((item.request.outputFolder as NSString).abbreviatingWithTildeInPath).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                }
                if item.state == .failed {
                    Section(L.get("Downloads_Error")) {
                        Text(item.statusText).font(.callout).textSelection(.enabled)
                        Button(L.get("Action_CopyError")) { copyError(item) }
                    }
                }
                Section {
                    actions(item)
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView(L.get("Downloads_NoSelection"), systemImage: "sidebar.trailing",
                                   description: Text(L.get("Downloads_NoSelectionBody")))
        }
    }

    @ViewBuilder private func actions(_ item: DownloadItem) -> some View {
        let downloads = model.downloads
        if let file = item.existingFile {
            Button(L.get("Menu_OpenFile")) { NSWorkspace.shared.open(file) }
        }
        Button(L.get("Menu_ShowInFinder")) { Finder.reveal(item.existingFile ?? item.folder) }
        if item.canPause { Button(L.get("Action_Pause")) { downloads.pause(item) } }
        if item.canResume { Button(L.get("Action_Resume")) { downloads.resume(item) } }
        if item.canRetry { Button(L.get(item.state == .completed ? "Action_Redownload" : "Action_Retry")) { downloads.retry(item) } }
        if item.canCancel { Button(L.get("Downloads_Cancel")) { downloads.cancel(item) } }
    }
}
