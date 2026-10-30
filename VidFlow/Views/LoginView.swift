import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import VidFlowCore
import WebKit

/// Sign-in for Bilibili / YouTube / Douyin, in a window of its own. Bilibili opens on a QR code to scan with its app (no
/// web page needed), with a link to the web page for password / SMS sign-in; the others go straight to the site. Either
/// way the cookies end up in the web profile and are exported to the Keychain when the window closes, which it does by
/// itself once the sign-in is detected.
final class LoginWindowController: NSObject, NSWindowDelegate {
    private static var open: [Platform: LoginWindowController] = [:]

    private let platform: Platform
    private let state: LoginState
    private var window: NSWindow?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var finished = false

    /// Shows the window (or brings it forward) and returns when it has closed and the cookies are saved.
    static func show(_ platform: Platform) async {
        await WebSession.prepare()
        let controller: LoginWindowController
        if let existing = open[platform] {
            controller = existing
            existing.window?.makeKeyAndOrderFront(nil)
        } else {
            controller = LoginWindowController(platform)
            open[platform] = controller
            controller.present()
        }
        await withCheckedContinuation { controller.waiters.append($0) }
    }

    private init(_ platform: Platform) {
        self.platform = platform
        state = LoginState(platform: platform)
    }

    private func present() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = switch platform {
        case .bilibili: L.get("Login_TitleBili")
        case .douyin: L.get("Login_TitleDouyin")
        default: L.get("Login_TitleYt")
        }
        window.isReleasedWhenClosed = false
        window.delegate = self
        state.close = { [weak window] in window?.close() }
        state.resize = { [weak window] size in
            guard let window else { return }
            window.setContentSize(size)
            window.center()
        }
        window.contentViewController = NSHostingController(rootView: LoginView(state: state))
        window.setContentSize(platform == .bilibili ? NSSize(width: 420, height: 520) : NSSize(width: 1000, height: 720))
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_: Notification) {
        guard !finished else { return }
        finished = true
        state.stop()
        Task {
            let app = AppModel.shared
            app.vault.store(await WebSession.exportable())
            app.accountsRevision += 1
            Self.open[platform] = nil
            let waiting = waiters
            waiters = []
            waiting.forEach { $0.resume() }
        }
    }
}

@Observable
final class LoginState {
    enum QR: Equatable { case loading, showing, scanned, expired, failed, success }

    let platform: Platform
    var showWeb: Bool
    var qrImage: NSImage?
    var qr: QR = .loading
    var signedIn = false

    @ObservationIgnored var close: () -> Void = {}
    @ObservationIgnored var resize: (NSSize) -> Void = { _ in }
    @ObservationIgnored private var qrTask: Task<Void, Never>?
    @ObservationIgnored private var closing = false

    init(platform: Platform) {
        self.platform = platform
        showWeb = platform != .bilibili
        if platform == .bilibili { runQR() }
    }

    func stop() { qrTask?.cancel() }

    func useWeb() {
        qrTask?.cancel()
        showWeb = true
        resize(NSSize(width: 1000, height: 720))
    }

    /// Called as web pages finish loading.
    func checkWebSession() {
        Task {
            guard !closing, await WebSession.hasSessionCookie(platform) else { return }
            signedIn = true
            // Let the site finish setting its cookies, then close (which saves them).
            closeSoon(after: 1.5)
        }
    }

    private func closeSoon(after delay: Double) {
        guard !closing else { return }
        closing = true
        Task {
            try? await Task.sleep(for: .seconds(delay))
            close()
        }
    }

    /// Gets a code, shows it, and follows it until it is confirmed, expires or the window moves on.
    func runQR() {
        qrTask?.cancel()
        qr = .loading
        qrTask = Task {
            do {
                let code = try await BilibiliQRLogin.generate()
                qrImage = Self.render(code.url)
                qr = .showing
                var failures = 0
                while true {
                    try await Task.sleep(for: .seconds(2))
                    let result: QRPollResult
                    do {
                        result = try await BilibiliQRLogin.poll(key: code.key)
                        failures = 0
                    } catch {
                        if error is CancellationError { throw error }
                        failures += 1
                        if failures < 5 { continue } // A dropped request or two: keep asking.
                        throw error
                    }
                    switch result.state {
                    case .waiting: break
                    case .scanned: qr = .scanned
                    case .expired:
                        qr = .expired
                        return
                    case .success:
                        await WebSession.add(result.cookies)
                        qr = .success
                        closeSoon(after: 0.8)
                        return
                    }
                }
            } catch is CancellationError {
            } catch {
                Log.warn("Bilibili QR login failed: \(error.localizedDescription)")
                if !Task.isCancelled { qr = .failed }
            }
        }
    }

    private static func render(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

private struct LoginView: View {
    let state: LoginState

    var body: some View {
        if state.showWeb {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: state.signedIn ? "checkmark.circle.fill" : "lock.fill")
                        .foregroundStyle(state.signedIn ? .green : .secondary)
                        .accessibilityHidden(true)
                    Text(statusText).foregroundStyle(.secondary)
                    Spacer()
                    Button(L.get("Login_Done")) { state.close() }
                }
                .padding(10)
                Divider()
                LoginWebView(state: state)
            }
        } else {
            QRPanel(state: state)
        }
    }

    private var statusText: String {
        if state.signedIn { return L.get("Login_SuccessClosing") }
        return state.platform == .douyin ? L.get("Login_InstructionsDouyin") : L.get("Login_Instructions")
    }
}

private struct QRPanel: View {
    let state: LoginState

    var body: some View {
        VStack(spacing: 16) {
            Text(L.get("Login_QrTitle")).font(.title2.weight(.semibold))
            Text(L.get("Login_QrHint")).foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.white)
                if let image = state.qrImage {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .padding(14)
                        .opacity(state.qr == .showing ? 1 : 0.12)
                        .accessibilityLabel(L.get("Login_QrHint"))
                }
                overlay
            }
            .frame(width: 240, height: 240)
            .environment(\.colorScheme, .light)
            Text(L.get("Login_StoredLocally")).font(.caption).foregroundStyle(.secondary)
            Button(L.get("Login_UseWeb")) { state.useWeb() }.buttonStyle(.link)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var overlay: some View {
        switch state.qr {
        case .showing: EmptyView()
        case .loading: ProgressView()
        case .scanned: status("iphone", L.get("Login_QrScanned"), .blue)
        case .success: status("checkmark.circle.fill", L.get("Login_QrSuccess"), .green)
        case .expired: retry("clock.arrow.circlepath", L.get("Login_QrExpired"), L.get("Login_QrRefresh"))
        case .failed: retry("exclamationmark.triangle.fill", L.get("Login_QrFailed"), L.get("Login_QrRetry"))
        }
    }

    private func status(_ icon: String, _ text: String, _ color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(color).accessibilityHidden(true)
            Text(text).multilineTextAlignment(.center).foregroundStyle(.black).padding(.horizontal, 16)
        }
    }

    private func retry(_ icon: String, _ text: String, _ action: String) -> some View {
        VStack(spacing: 10) {
            status(icon, text, .secondary)
            Button(action) { state.runQR() }
        }
    }
}

private struct LoginWebView: NSViewRepresentable {
    let state: LoginState

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WebSession.store
        let web = WKWebView(frame: .zero, configuration: config)
        // WKWebView's default identifier has no browser name, which some sign-in pages reject.
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.load(URLRequest(url: WebSession.loginURL(state.platform)))
        return web
    }

    func updateNSView(_: WKWebView, context _: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let state: LoginState
        init(state: LoginState) { self.state = state }

        func webView(_: WKWebView, didFinish _: WKNavigation!) { state.checkWebSession() }

        /// Keep pop-ups (e.g. third-party login) inside this window.
        func webView(_ web: WKWebView, createWebViewWith _: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures _: WKWindowFeatures) -> WKWebView? {
            if action.targetFrame == nil { web.load(action.request) }
            return nil
        }
    }
}
