import CoreTransferable
import SwiftUI
import VidFlowCore

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var dropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .dropDestination(for: DroppedLink.self) { items, _ in
            let text = items.map(\.text).joined(separator: " ")
            guard !UrlTools.extractURLs(text).isEmpty else { return false }
            model.open(links: text)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.accentColor.opacity(0.08))
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                    Label(L.get("Drop_Hint"), systemImage: "arrow.down.circle.fill")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
                .padding(8)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: dropTargeted)
        .sheet(isPresented: $model.showFirstRun) { FirstRunView() }
    }
}

/// A link dragged from a browser arrives as a URL, selected text as a string.
nonisolated struct DroppedLink: Transferable {
    var text: String

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(importing: { (url: URL) in DroppedLink(text: url.absoluteString) })
        ProxyRepresentation(importing: { (text: String) in DroppedLink(text: text) })
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
            Label {
                Text(L.get("Nav_Downloads"))
            } icon: {
                // A hop when something joins the queue, so it's clear where it went.
                Image(systemName: "arrow.down.circle")
                    .symbolEffect(.bounce, value: model.downloads.addedCount)
            }
                .badge(model.downloads.activeCount)
                .tag(SidebarItem.downloads(.all))
            Label(L.get("Nav_Templates"), systemImage: "slider.horizontal.3").tag(SidebarItem.templates)
        }
        .listStyle(.sidebar)
        // Pinned under the list with a picture and a name, as the App Store and Music do.
        .safeAreaInset(edge: .bottom, spacing: 0) { AccountEntry() }
    }
}

/// The account's place at the foot of the sidebar.
private struct AccountEntry: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    private var signedIn: Int {
        _ = model.accountsRevision
        return CookieVault.signInPlatforms.filter(model.vault.isLoggedIn).count
    }

    var body: some View {
        let selected = model.sidebar == .accounts
        Button {
            model.sidebar = .accounts
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(L.get("Nav_Accounts")).lineLimit(1)
                    Text(signedIn > 0 ? L.format("Accounts_SignedInCount", signedIn) : L.get("Accounts_NotSignedIn"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background(selected ? AnyShapeStyle(.quaternary) : hovering ? AnyShapeStyle(.quinary) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .padding(.top, 4)
        .accessibilityLabel(L.get("Nav_Accounts"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// An image from the web, through VidFlow's own proxy settings, cached in memory.
struct RemoteImage: View {
    let url: String?
    /// Shown, faintly, until the picture arrives or if there isn't one.
    var platform: Platform?
    @State private var image: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).transition(.opacity)
            } else if let platform, platform != .other {
                Image(platform.assetName).resizable().aspectRatio(contentMode: .fit).frame(width: 22, height: 22).opacity(0.45)
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
                withAnimation(reduceMotion ? nil : .easeIn(duration: 0.2)) { image = loaded }
            }
        }
    }
}

/// A short status banner, in the system's own colours and symbols.
struct MessageBanner: View {
    let message: ComposerMessage
    var onLogin: (Platform) -> Void = { _ in }
    var onDismiss: (() -> Void)?
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
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L.get("Common_Close"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
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
