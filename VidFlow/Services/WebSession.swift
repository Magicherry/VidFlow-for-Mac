import Foundation
import WebKit
import VidFlowCore

/// The web profile for in-app sign-in and for Douyin's page script. It lives in memory only, so the Keychain (see
/// `CookieVault`) is the one place sign-ins rest: each run fills the profile from there, and exports back to it.
enum WebSession {
    private static let sites = ["bilibili.com", "youtube.com", "google.com", "douyin.com"]

    static let store = WKWebsiteDataStore.nonPersistent()
    private static var prepared = false

    /// Fills the profile from the Keychain, once. Call before anything uses or exports the profile.
    static func prepare() async {
        guard !prepared else { return }
        prepared = true
        await add(CookieVault.parseNetscape(AppModel.shared.vault.storedText ?? ""))
    }

    static func loginURL(_ p: Platform) -> URL {
        switch p {
        case .bilibili: URL(string: "https://passport.bilibili.com/login")!
        case .douyin: URL(string: "https://www.douyin.com/")!
        default: URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fwww.youtube.com%2F")!
        }
    }

    static func allCookies() async -> [HTTPCookie] {
        await store.httpCookieStore.allCookies()
    }

    static func hasSessionCookie(_ p: Platform) async -> Bool {
        let names = CookieVault.sessionCookieNames(p)
        let domain = CookieVault.domain(p)
        return await allCookies().contains { $0.domain.lowercased().hasSuffix(domain) && names.contains($0.name) }
    }

    /// The current cookies of the supported sites, in VidFlow's form.
    static func exportable() async -> [CookieRecord] {
        await prepare()
        return await allCookies().filter { c in sites.contains { c.domain.lowercased().hasSuffix($0) } }.map(record)
    }

    private static func record(_ c: HTTPCookie) -> CookieRecord {
        CookieRecord(domain: c.domain, path: c.path, name: c.name, value: c.value, secure: c.isSecure, httpOnly: c.isHTTPOnly,
                     expires: c.expiresDate.map { Int64($0.timeIntervalSince1970) } ?? 0)
    }

    /// Adds cookies obtained outside the browser (QR login) to the profile, which stays the one source of truth: later
    /// exports and sign-outs then include them.
    static func add(_ cookies: [CookieRecord]) async {
        for c in cookies {
            var props: [HTTPCookiePropertyKey: Any] = [.domain: c.domain, .path: c.path, .name: c.name, .value: c.value]
            if c.secure { props[.secure] = "TRUE" }
            if c.expires > 0 { props[.expires] = Date(timeIntervalSince1970: TimeInterval(c.expires)) }
            if c.httpOnly { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let cookie = HTTPCookie(properties: props) { await store.httpCookieStore.setCookie(cookie) }
        }
    }

    /// Signs out of one platform: clears its cookies from the profile and returns what remains, to export.
    static func removeCookies(for p: Platform) async -> [CookieRecord] {
        await prepare()
        let domains = p == .youTube ? ["youtube.com", "google.com"] : [CookieVault.domain(p)]
        for c in await allCookies() where domains.contains(where: { c.domain.lowercased().hasSuffix($0) }) {
            await store.httpCookieStore.deleteCookie(c)
        }
        return await exportable()
    }
}

/// Opens a Douyin video page in a hidden WKWebView (the shared profile, so a Douyin sign-in applies) and returns the
/// JSON of the "aweme/detail" request the page makes for it. Douyin signs that request in page script, which is why the
/// page has to make it. WKWebView has no API to read response bodies, so a script injected ahead of the page's own
/// wraps fetch and XMLHttpRequest and hands that one response over. The page is muted and its media blocked.
final class DouyinFetcher {
    private static let timeout: Duration = .seconds(30)
    /// One hidden page at a time (a batch parses several links at once).
    private var tail: Task<Void, Never>?
    private var blockMedia: WKContentRuleList?

    nonisolated func fetchDetail(videoURL: String) async throws -> String {
        try await enqueue(videoURL)
    }

    private func enqueue(_ videoURL: String) async throws -> String {
        let previous = tail
        let work = Task { () throws -> String in
            await previous?.value
            return try await self.load(videoURL)
        }
        tail = Task { _ = try? await work.value }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    private static let hook = """
    (() => {
      const wanted = u => String(u).includes('/aweme/v1/web/aweme/detail/');
      const send = body => { try { if (body) webkit.messageHandlers.vidflow.postMessage(body); } catch (e) {} };
      const realFetch = window.fetch;
      window.fetch = function (input) {
        const url = typeof input === 'string' ? input : (input && input.url) || '';
        const result = realFetch.apply(this, arguments);
        if (wanted(url)) result.then(r => r.clone().text()).then(send).catch(() => {});
        return result;
      };
      const open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url) {
        if (wanted(url)) this.addEventListener('load', () => send(this.responseText));
        return open.apply(this, arguments);
      };
    })();
    """

    private func ruleList() async -> WKContentRuleList? {
        if let blockMedia { return blockMedia }
        let rules = #"[{"trigger":{"url-filter":".*","resource-type":["media"]},"action":{"type":"block"}}]"#
        blockMedia = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "vidflow-no-media", encodedContentRuleList: rules)
        return blockMedia
    }

    private func load(_ videoURL: String) async throws -> String {
        await WebSession.prepare()
        guard let url = URL(string: videoURL) else { throw YtDlpError(L.get("Error_DouyinUnavailable")) }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WebSession.store
        config.mediaTypesRequiringUserActionForPlayback = .all
        let receiver = DetailReceiver()
        config.userContentController.add(receiver, name: "vidflow")
        config.userContentController.addUserScript(WKUserScript(source: Self.hook, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let rules = await ruleList() { config.userContentController.add(rules) }
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        web.customUserAgent = HTTPClient.userAgent
        defer {
            web.stopLoading()
            config.userContentController.removeScriptMessageHandler(forName: "vidflow")
        }
        web.load(URLRequest(url: url))
        let timeout = Task {
            try await Task.sleep(for: Self.timeout)
            receiver.fail(YtDlpError(L.get("Error_DouyinUnavailable")))
        }
        defer { timeout.cancel() }
        return try await receiver.wait()
    }

    private final class DetailReceiver: NSObject, WKScriptMessageHandler {
        private var body: String?
        private var waiter: CheckedContinuation<String, Error>?

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let text = message.body as? String, !text.isEmpty, body == nil else { return }
            body = text
            waiter?.resume(returning: text)
            waiter = nil
        }

        func fail(_ error: Error) {
            waiter?.resume(throwing: error)
            waiter = nil
        }

        func wait() async throws -> String {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
                    if let body { c.resume(returning: body) } else { waiter = c }
                }
            } onCancel: {
                Task { @MainActor in
                    self.fail(CancellationError())
                }
            }
        }
    }
}
