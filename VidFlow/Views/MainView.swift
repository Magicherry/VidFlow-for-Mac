import SwiftUI
import VidFlowCore

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            switch model.sidebar {
            case .newDownload: NewDownloadView()
            case .downloads(let filter): DownloadsView(status: filter)
            case .templates: TemplatesView()
            case .accounts: AccountsView()
            }
        }
        .modifier(ActionBridge())
        .dropDestination(for: String.self) { items, _ in
            let text = items.joined(separator: " ")
            guard !UrlTools.extractURLs(text).isEmpty else { return false }
            model.open(links: text)
            return true
        }
        .sheet(isPresented: $model.showFirstRun) { FirstRunView() }
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: Binding<SidebarItem?>(get: {
            if case .downloads = model.sidebar { return .downloads(.all) }
            // Accounts has no row here. A selection the list can't find makes it pick its first row by itself.
            if model.sidebar == .accounts { return nil }
            return model.sidebar
        }, set: { item in
            guard let item else { return }
            if case .downloads = item, case .downloads = model.sidebar { return } // Keeps the list's filter.
            model.sidebar = item
        })) {
            Label(L.get("Nav_Home"), systemImage: "plus.circle").tag(SidebarItem.newDownload)
            Label(L.get("Nav_Downloads"), systemImage: "arrow.down.circle")
                .badge(model.downloads.activeCount)
                .tag(SidebarItem.downloads(.all))
            Label(L.get("Nav_Templates"), systemImage: "slider.horizontal.3").tag(SidebarItem.templates)
        }
        .listStyle(.sidebar)
        // Pinned under the list, the way apps keep the account apart from their content.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                model.sidebar = .accounts
            } label: {
                Label(L.get("Nav_Accounts"), systemImage: "person.crop.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .background(model.sidebar == .accounts ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .padding(10)
            .accessibilityAddTraits(model.sidebar == .accounts ? .isSelected : [])
        }
    }
}

/// An image from the web, through VidFlow's own proxy settings, cached in memory.
struct RemoteImage: View {
    let url: String?
    @State private var image: NSImage?

    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "film").foregroundStyle(.tertiary)
            }
        }
        .clipped()
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url, let address = URL(string: url) else {
                image = nil
                return
            }
            if let hit = Self.cache.object(forKey: url as NSString) {
                image = hit
                return
            }
            var req = URLRequest(url: address)
            // Bilibili's and Weibo's image hosts refuse requests from elsewhere; their own pages are what they expect.
            switch UrlTools.detectPlatform(url) {
            case .other: break
            default: req.setValue(address.scheme.map { "\($0)://\(address.host ?? "")/" }, forHTTPHeaderField: "Referer")
            }
            if let (data, _) = try? await HTTPClient.shared.data(for: req), let loaded = NSImage(data: data) {
                Self.cache.setObject(loaded, forKey: url as NSString)
                image = loaded
            }
        }
    }
}

/// A short status banner, in the system's own colours and symbols.
struct MessageBanner: View {
    let message: ComposerMessage
    var onLogin: (Platform) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let title = message.title { Text(title).fontWeight(.semibold) }
                Text(message.text).foregroundStyle(message.title == nil ? .primary : .secondary).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if let platform = message.loginPlatform {
                Button(L.get("Home_LoginNow")) { onLogin(platform) }
            }
            if message.showDownloads {
                Button(L.get("Home_ViewDownloads")) { model.sidebar = .downloads(.all) }
            }
            if message.openComponents {
                Button(L.get("Home_ComponentsAction")) { model.openSettings(.updates) }
            }
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel(L.get("Common_Close"))
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var symbol: String {
        switch message.kind {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .success: "checkmark.circle.fill"
        }
    }

    private var color: Color {
        switch message.kind {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        case .success: .green
        }
    }
}
