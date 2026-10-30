import CFNetwork
import CryptoKit
import Foundation

/// HTTP through a URLSession that honours the proxy from settings (or the system's, when there is none).
public final class HTTPClient: @unchecked Sendable {
    public static let shared = HTTPClient()

    public static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"

    private let cached = Locked<(proxy: String, session: URLSession)?>(nil)

    public init() {}

    /// Rebuilt when the proxy setting changes.
    public var session: URLSession {
        let proxy = SettingsStore.shared.current.proxy.trimmingCharacters(in: .whitespaces)
        return cached.withLock { state in
            if let state, state.proxy == proxy { return state.session }
            let session = URLSession(configuration: Self.configuration(proxy: proxy))
            state = (proxy, session)
            return session
        }
    }

    public static func configuration(proxy: String) -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.httpAdditionalHeaders = ["User-Agent": userAgent]
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 600
        if let dict = proxyDictionary(proxy) { c.connectionProxyDictionary = dict }
        return c
    }

    /// "http://host:port", "socks5://host:port" → URLSession's proxy keys; nil for an empty or invalid value, which
    /// leaves the system proxy in charge.
    static func proxyDictionary(_ proxy: String) -> [AnyHashable: Any]? {
        guard !proxy.isEmpty, let url = URL(string: proxy.contains("://") ? proxy : "http://\(proxy)"), let host = url.host else { return nil }
        let scheme = url.scheme?.lowercased() ?? "http"
        if scheme.hasPrefix("socks") {
            return ["SOCKSEnable": 1, "SOCKSProxy": host, "SOCKSPort": url.port ?? 1080]
        }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return ["HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port, "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port]
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else { throw HTTPStatusError(code: http.statusCode) }
        return (data, http)
    }

    public func string(from url: URL) async throws -> String {
        String(decoding: try await data(for: URLRequest(url: url)).0, as: UTF8.self)
    }

    /// The address a link ends up on after its redirects.
    public func finalURL(of url: URL) async throws -> URL? {
        var req = URLRequest(url: url)
        // One byte rather than HEAD, which not every download server answers.
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        return try await data(for: req).1.url
    }

    /// The proxy the system would use for HTTPS ("http://host:port"), for tools that don't look it up themselves.
    public static func systemProxy() -> String? {
        guard let s = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return nil }
        if (s[kCFNetworkProxiesHTTPSEnable as String] as? NSNumber)?.boolValue == true,
           let host = s[kCFNetworkProxiesHTTPSProxy as String] as? String,
           let port = s[kCFNetworkProxiesHTTPSPort as String] as? NSNumber {
            return "http://\(host):\(port)"
        }
        if (s[kCFNetworkProxiesHTTPEnable as String] as? NSNumber)?.boolValue == true,
           let host = s[kCFNetworkProxiesHTTPProxy as String] as? String,
           let port = s[kCFNetworkProxiesHTTPPort as String] as? NSNumber {
            return "http://\(host):\(port)"
        }
        return nil
    }
}

public struct HTTPStatusError: LocalizedError, Sendable {
    public var code: Int
    public var errorDescription: String? { "HTTP \(code)" }
}

/// Downloads a file over several connections at once. Through many proxies (and from GitHub's release CDN) a single
/// connection's speed swings widely; spreading the file over several keeps it fast. The file is cut into chunks that a
/// few workers take in turn, so one slow connection only holds up its current chunk. Servers that don't support ranges
/// get a plain single-connection download.
public enum FileDownloader {
    public static func download(from url: URL, to dest: URL, http: HTTPClient = .shared, connections: Int = 8,
                                progress: (@Sendable (Double) -> Void)? = nil) async throws {
        var probe = URLRequest(url: url)
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, response) = try await http.data(for: probe)
        let total = response.statusCode == 206 ? totalSize(response) : 0
        let target = response.url ?? url
        try? FileManager.default.removeItem(at: dest)

        guard connections > 1, total >= 4 << 20 else {
            let (temp, resp) = try await http.session.download(for: URLRequest(url: url), delegate: ProgressDelegate(progress))
            guard let code = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else {
                throw HTTPStatusError(code: (resp as? HTTPURLResponse)?.statusCode ?? 0)
            }
            try FileManager.default.moveItem(at: temp, to: dest)
            progress?(100)
            return
        }

        // About 32 chunks (1–8 MB each): enough that the workers keep swapping slow connections for new ones.
        let chunkSize = Swift.min(Swift.max(total / 32, 1 << 20), 8 << 20)
        guard FileManager.default.createFile(atPath: dest.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let writer = ChunkWriter(handle: try FileHandle(forWritingTo: dest), total: total, progress: progress)
        defer { writer.close() }
        let chunks = stride(from: Int64(0), to: total, by: Int(chunkSize)).map { ($0, Swift.min($0 + chunkSize, total) - 1) }
        let queue = Locked(chunks[...])

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<Swift.min(connections, chunks.count) {
                group.addTask {
                    while let (from, to) = queue.withLock({ $0.popFirst() }) {
                        try await fetch(original: url, target: target, from: from, to: to, http: http, writer: writer)
                    }
                }
            }
            try await group.waitForAll()
        }
        progress?(100)
    }

    private static func fetch(original: URL, target: URL, from: Int64, to: Int64, http: HTTPClient, writer: ChunkWriter) async throws {
        var target = target
        for attempt in 1...4 {
            do {
                var req = URLRequest(url: target)
                req.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
                req.timeoutInterval = 120
                let (data, resp) = try await http.data(for: req)
                guard resp.statusCode == 206, Int64(data.count) == to - from + 1 else { throw URLError(.networkConnectionLost) }
                try await writer.write(data, at: from)
                return
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled || attempt == 4 { throw error }
                Log.info("Chunk \(from)-\(to) attempt \(attempt) failed: \(error.localizedDescription)")
                // Signed CDN addresses expire after a few minutes: ask the original address again.
                if let status = error as? HTTPStatusError, [403, 404, 410].contains(status.code) {
                    var probe = URLRequest(url: original)
                    probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
                    if let (_, fresh) = try? await http.data(for: probe), let url = fresh.url { target = url }
                }
                try await Task.sleep(for: .seconds(attempt))
            }
        }
    }

    /// "Content-Range: bytes 0-0/12345" → 12345.
    private static func totalSize(_ r: HTTPURLResponse) -> Int64 {
        r.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap { Int64($0) } ?? 0
    }

    private actor ChunkWriterState {
        var done: Int64 = 0
        func add(_ n: Int64) -> Int64 {
            done += n
            return done
        }
    }

    private final class ChunkWriter: Sendable {
        private let handle: Locked<FileHandle>
        private let total: Int64
        private let progress: (@Sendable (Double) -> Void)?
        private let state = ChunkWriterState()

        init(handle: FileHandle, total: Int64, progress: (@Sendable (Double) -> Void)?) {
            self.handle = Locked(handle)
            self.total = total
            self.progress = progress
        }

        func write(_ data: Data, at offset: Int64) async throws {
            try handle.withLock {
                try $0.seek(toOffset: UInt64(offset))
                try $0.write(contentsOf: data)
            }
            let done = await state.add(Int64(data.count))
            progress?(Double(done) * 100 / Double(total))
        }

        func close() { handle.withLock { try? $0.close() } }
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
        let report: (@Sendable (Double) -> Void)?
        init(_ report: (@Sendable (Double) -> Void)?) { self.report = report }
        func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didFinishDownloadingTo _: URL) {}
        func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didWriteData _: Int64,
                        totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
            if expected > 0 { report?(Double(written) * 100 / Double(expected)) }
        }
    }

    /// Lower-case hex SHA-256 of a file, read in pieces.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let piece = try handle.read(upToCount: 1 << 20), !piece.isEmpty { hasher.update(data: piece) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Turns share links into the page links the downloaders understand: Douyin (v.douyin.com, share pages, feed links) to
/// douyin.com/video/ID, Weibo (t.cn, video.weibo.com/show?fid=) to weibo.com/tv/show/ID, and Xiaohongshu (xhslink.com)
/// to its note page, keeping the access token the link carries.
public enum ShortLinks {
    /// Stops URLSession at each redirect, so the hops can be taken one by one.
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                        newRequest _: URLRequest) async -> URLRequest? { nil }
    }

    public static func normalize(_ url: String, http: HTTPClient = .shared) async throws -> String {
        if let direct = UrlTools.canonical(url) { return direct }
        guard UrlTools.isShortLink(url), var current = URL(string: url) else { return url }
        // Follow the shortener's redirects by hand, only as far as the first page on the platform itself: going
        // further would land on its login / visitor check page instead of the video.
        let delegate = NoRedirect()
        var hop = 0
        while hop < 5, UrlTools.isShortLink(current.absoluteString) {
            hop += 1
            var req = URLRequest(url: current)
            req.timeoutInterval = 15
            let (_, resp) = try await http.session.data(for: req, delegate: delegate)
            guard let location = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"),
                  let next = URL(string: location, relativeTo: current)?.absoluteURL else { break }
            current = next
        }
        let resolved = current.absoluteString
        if resolved == url { Log.info("Short link didn't redirect anywhere: \(url)") }
        return UrlTools.canonical(resolved) ?? resolved
    }
}

/// Outcome of one reachability check.
public struct ConnectivityResult: Sendable, Equatable {
    public var reachable: Bool
    public var latency: TimeInterval
    public var error: String?
    public var checkedAt: Date
}

/// Whether sites outside the Great Firewall (YouTube, and with it X) can be reached with the current proxy setting. An
/// HTTPS request rather than a ping: proxies such as Clash only carry TCP, so ICMP fails even when downloads work. Any
/// HTTP answer counts as reachable; a timeout or a connection error does not.
public enum Connectivity {
    /// YouTube's own "no content" address: tiny, quick, and only answers when YouTube itself is reachable.
    public static let youTubeProbe = URL(string: "https://www.youtube.com/generate_204")!

    /// Platforms blocked in mainland China, so reachable only through a proxy there; the YouTube check stands for them all.
    public static func needsProxy(_ p: Platform) -> Bool { p == .youTube || p == .x }

    public static func check(_ url: URL = youTubeProbe, http: HTTPClient = .shared, timeout: TimeInterval = 8) async -> ConnectivityResult {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        let start = Date()
        do {
            _ = try await http.session.data(for: req)
            return ConnectivityResult(reachable: true, latency: Date().timeIntervalSince(start), error: nil, checkedAt: Date())
        } catch {
            return ConnectivityResult(reachable: false, latency: Date().timeIntervalSince(start),
                                      error: error.localizedDescription, checkedAt: Date())
        }
    }
}
