import SwiftUI
import VidFlowCore

struct DownloadsView: View {
    let status: DownloadStatusFilter
    @Environment(AppModel.self) private var model
    @State private var selection = Set<UUID>()
    @State private var platform: Platform?
    @State private var query = ""
    @State private var sortOrder = [DownloadSort(field: .added, order: .reverse)]

    private var downloads: DownloadManager { model.downloads }

    private var filter: DownloadFilter { DownloadFilter(status: status, platform: platform, query: query) }

    private var shown: [DownloadItem] {
        let filter = self.filter
        return downloads.items.filter { filter.matches(state: $0.state, title: $0.title, url: $0.request.url, platform: $0.platform) }
            .sorted(using: sortOrder)
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
                table(rows)
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

    private func table(_ rows: [DownloadItem]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(L.get("Downloads_Name"), sortUsing: DownloadSort(field: .name)) { item in
                NameCell(item: item)
            }
            .width(min: 220, ideal: 360)
            TableColumn(L.get("Downloads_Status"), sortUsing: DownloadSort(field: .status)) { item in
                StatusCell(item: item)
            }
            .width(min: 180, ideal: 260)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            RowMenu(items: downloads.items.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            for item in downloads.items where ids.contains(item.id) { open(item) }
        }
        .onDeleteCommand {
            selectedItems.forEach(downloads.remove)
            selection = []
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
                Picker(L.get("Downloads_Platform"), selection: $platform) {
                    Text(L.get("Downloads_AllPlatforms")).tag(Platform?.none)
                    ForEach(Platform.supported) { Text($0.displayName).tag(Platform?.some($0)) }
                }
                .pickerStyle(.inline)
                Divider()
                Button(L.get("Downloads_ClearFinished")) { downloads.clearFinished() }
                    .disabled(!downloads.canClearFinished)
            } label: {
                Label(L.get("Downloads_More"), systemImage: status == .all && platform == nil
                      ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
            }
            .help(L.get("Downloads_More"))
        }
    }
}

/// The table's sort orders. Rows are main-actor objects and the table compares them on the main actor.
nonisolated struct DownloadSort: SortComparator, Hashable {
    enum Field: Hashable { case name, status, added }
    var field: Field
    var order: SortOrder = .forward

    func compare(_ a: DownloadItem, _ b: DownloadItem) -> ComparisonResult {
        let result = MainActor.assumeIsolated { () -> ComparisonResult in
            switch field {
            case .name: return a.title.localizedStandardCompare(b.title)
            case .added: return a.addedAt.compare(b.addedAt)
            case .status:
                return a.statusOrder == b.statusOrder ? .orderedSame : a.statusOrder < b.statusOrder ? .orderedAscending : .orderedDescending
            }
        }
        guard order == .reverse else { return result }
        return result == .orderedAscending ? .orderedDescending : result == .orderedDescending ? .orderedAscending : .orderedSame
    }
}

extension DownloadItem {
    /// The status line with speed and time left, so one column says it all.
    var liveStatus: String {
        var parts = [statusText]
        if speed > 0 { parts.append("\(Format.bytes(speed))/s") }
        if eta > 0 { parts.append(L.format("Status_Remaining", Format.duration(eta))) }
        return parts.joined(separator: " · ")
    }

    var addedAt: Date { createdAt }
    /// Rows that need attention first when sorting by status.
    var statusOrder: Int {
        switch state {
        case .failed: 0
        case .downloading, .processing: 1
        case .queued: 2
        case .paused: 3
        case .canceled: 4
        case .completed: 5
        }
    }
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

private struct NameCell: View {
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 10) {
            RemoteImage(url: item.thumbnailURL)
                .frame(width: 56, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1).help(item.title)
                Text(item.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct StatusCell: View {
    let item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch item.state {
            case .downloading, .paused:
                ProgressView(value: min(item.progress, 100), total: 100)
                    .controlSize(.small)
                    .tint(item.state == .paused ? .secondary : .accentColor)
            case .processing:
                ProgressView().progressViewStyle(.linear).controlSize(.small)
            default:
                EmptyView()
            }
            HStack(spacing: 4) {
                if item.state == .failed || item.fileMissing {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(item.fileMissing ? .orange : .red).accessibilityHidden(true)
                } else if item.state == .completed {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
                }
                Text(item.fileMissing ? L.get("Status_FileMissing") : item.state == .completed ? L.get("Status_Completed") : item.liveStatus)
                    .font(.caption)
                    .foregroundStyle(item.state == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .help(item.statusText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.stateLabel), \(item.statusText)")
        .accessibilityValue(item.isActive ? "\(Int(item.progress))%" : "")
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
                    RemoteImage(url: item.thumbnailURL)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text(item.title).fontWeight(.semibold).textSelection(.enabled)
                }
                Section {
                    LabeledContent(L.get("Downloads_Status"), value: item.stateLabel)
                    if item.isActive || item.state == .paused {
                        LabeledContent("%", value: String(format: "%.1f", item.progress))
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
