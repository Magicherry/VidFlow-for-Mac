import Darwin
import Foundation
import Testing
@testable import VidFlowCore

/// Every test lives under this one serialized root: they share process-wide state (AppPaths.dataDir, the UI language,
/// the cookie session folder in the temp directory), and Swift Testing would otherwise run them in parallel.
@Suite("VidFlowCore", .serialized)
struct VidFlowCoreTests {}

struct TestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum TestEnv {
    /// A throwaway data folder for the whole run, so no test can touch ~/Library/Application Support/VidFlow.
    static let root: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vidflow-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func prepare() { AppPaths.dataDir = root }
}

/// Runs `body` with AppPaths.dataDir pointing at a fresh folder, removed afterwards.
func withDataDir<T>(_ body: (URL) throws -> T) throws -> T {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vidflow-test-\(UUID().uuidString)", isDirectory: true)
    AppPaths.dataDir = dir
    defer {
        AppPaths.dataDir = TestEnv.root
        try? FileManager.default.removeItem(at: dir)
    }
    return try body(dir)
}

func withDataDirAsync<T>(_ body: (URL) async throws -> T) async throws -> T {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vidflow-test-\(UUID().uuidString)", isDirectory: true)
    AppPaths.dataDir = dir
    defer {
        AppPaths.dataDir = TestEnv.root
        try? FileManager.default.removeItem(at: dir)
    }
    return try await body(dir)
}

func near(_ a: Double, _ b: Double, tolerance: Double = 0.001) -> Bool { abs(a - b) <= tolerance }

extension Array where Element == String {
    /// The argument following `flag`, like `args[args.IndexOf(flag) + 1]`.
    func value(after flag: String) -> String? {
        guard let i = firstIndex(of: flag), i + 1 < count else { return nil }
        return self[i + 1]
    }
}

func progress(_ event: DownloadEvent?) throws -> DownloadProgress {
    guard case .progress(let p)? = event else { throw TestError("expected a progress event, got \(String(describing: event))") }
    return p
}

func video(_ json: String, _ url: String) throws -> VideoInfo {
    guard case .video(let v) = try InfoParser.parse(json, requestedURL: url) else { throw TestError("expected a video") }
    return v
}

func playlist(_ json: String, _ url: String) throws -> PlaylistInfo {
    guard case .playlist(let p) = try InfoParser.parse(json, requestedURL: url) else { throw TestError("expected a playlist") }
    return p
}

func makeRequest(_ url: String = "https://www.youtube.com/watch?v=x", mode: String = "video", height: Int = 0,
                 subs: Bool = false, _ configure: (inout DownloadRequest) -> Void = { _ in }) -> DownloadRequest {
    var r = DownloadRequest(url: url, mode: mode, maxHeight: height, writeSubtitles: subs, outputFolder: "/out")
    configure(&r)
    return r
}

func makeSettings(_ configure: (inout AppSettings) -> Void = { _ in }) -> AppSettings {
    var s = AppSettings()
    configure(&s)
    return s
}

func makeTemplate(_ configure: (inout DownloadTemplate) -> Void = { _ in }) -> DownloadTemplate {
    var t = DownloadTemplate()
    configure(&t)
    return t
}

enum Env {
    static let withFfmpeg = YtDlpArgs.Environment(ffmpegDir: "/opt/ff")
    static let noFfmpeg = YtDlpArgs.Environment()
}

func download(_ r: DownloadRequest, _ s: AppSettings = AppSettings(), _ e: YtDlpArgs.Environment = Env.withFfmpeg) -> [String] {
    YtDlpArgs.download(r, settings: s, env: e)
}

// MARK: - A tiny HTTP server on the loopback interface (no network involved)

final class LocalServer: @unchecked Sendable {
    struct Request: Sendable {
        var path: String
        var range: String?
    }

    let port: UInt16
    private let stopped = Locked(false)

    /// `handler` writes the whole answer to the descriptor; the connection is closed when it returns.
    init(handler: @escaping @Sendable (Request, Int32) -> Void) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 128) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        port = UInt16(bigEndian: addr.sin_port)

        let stopped = self.stopped
        DispatchQueue.global().async {
            while !stopped.current {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&pfd, 1, 100) > 0 else { continue }
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                var one: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                DispatchQueue.global().async { Self.serve(client, handler) }
            }
            close(fd)
        }
    }

    func stop() { stopped.current = true }

    private static func serve(_ client: Int32, _ handler: @Sendable (Request, Int32) -> Void) {
        defer { close(client) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let end = Data("\r\n\r\n".utf8)
        while data.range(of: end) == nil {
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { return }
            data.append(contentsOf: buffer[0..<n])
            if data.count > 65536 { return }
        }
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
        let path = lines[0].split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let range = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }
            .map { $0.dropFirst("range:".count).trimmingCharacters(in: .whitespaces) }
        handler(Request(path: path, range: range), client)
    }

    @discardableResult
    static func send(_ fd: Int32, _ bytes: ArraySlice<UInt8>) -> Bool {
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
    }

    @discardableResult
    static func send(_ fd: Int32, _ text: String) -> Bool { send(fd, Array(text.utf8)[...]) }
}

/// One file served over HTTP: answers range requests (or ignores them), and can cut the first few ranged responses
/// short to test retries.
final class FileServer: @unchecked Sendable {
    let data: [UInt8]
    let requests = Locked(0)
    let rangeRequests = Locked(0)
    private let cutFirst: Locked<Int>
    private var server: LocalServer!

    var url: URL { URL(string: "http://127.0.0.1:\(server.port)/file")! }

    init(size: Int, ranges: Bool, cutFirst: Int = 0) throws {
        var bytes = [UInt8](repeating: 0, count: size)
        var x: UInt64 = 42
        for i in bytes.indices {
            x = x &* 6364136223846793005 &+ 1442695040888963407
            bytes[i] = UInt8(truncatingIfNeeded: x >> 33)
        }
        data = bytes
        self.cutFirst = Locked(cutFirst)
        server = try LocalServer { [unowned self] request, fd in self.serve(request, fd, ranges: ranges) }
    }

    func stop() { server.stop() }

    private func serve(_ request: LocalServer.Request, _ fd: Int32, ranges: Bool) {
        requests.withLock { $0 += 1 }
        var from = 0
        var to = data.count - 1
        var head = "HTTP/1.1 200 OK\r\n"
        if ranges, let range = request.range {
            rangeRequests.withLock { $0 += 1 }
            let spec = range.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            from = Int(spec[0]) ?? 0
            if spec.count > 1, let t = Int(spec[1]) { to = min(t, data.count - 1) }
            head = "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(from)-\(to)/\(data.count)\r\n"
        }
        let length = to - from + 1
        head += "Content-Length: \(length)\r\nConnection: close\r\n\r\n"
        guard LocalServer.send(fd, head) else { return }
        // Cut short: send half, then drop the connection.
        let cut = from > 0 && cutFirst.withLock { n -> Bool in
            n -= 1
            return n >= 0
        }
        if cut {
            LocalServer.send(fd, data[from..<(from + length / 2)])
            return
        }
        LocalServer.send(fd, data[from...to])
    }
}
