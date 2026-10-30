import Foundation

extension ErrorMapper {
    /// A failure that may well go away by itself: the network, a server having a bad moment, a rate limit. Not one that
    /// repeats whatever happens (private video, unsupported link, no formats, disk full).
    public static func isTransient(_ error: String) -> Bool {
        let line = lastErrorLine(error)
        return ["timed out", "Connection reset", "Connection refused", "Connection aborted", "getaddrinfo", "nodename nor servname",
                "Network is unreachable", "Network is down", "Temporary failure", "Unable to download", "SSL", "EOF occurred",
                "HTTP Error 429", "Too Many Requests", "HTTP Error 500", "HTTP Error 502", "HTTP Error 503", "HTTP Error 504",
                "IncompleteRead", "Got error", "RemoteDisconnected", "ProxyError", "Tunnel connection failed"]
            .contains { line.containsIgnoringCase($0) }
            && !["Video unavailable", "Unsupported URL", "Private video"].contains { line.containsIgnoringCase($0) }
    }

    public static func isDiskFull(_ error: String) -> Bool {
        error.containsIgnoringCase("No space left") || error.containsIgnoringCase("Errno 28")
    }
}

/// How often and how soon a failed download tries again by itself.
public enum RetryPolicy {
    public static let maxAttempts = 3

    /// Seconds before attempt `n` (1-based): 5, 15, 45.
    public static func delay(attempt n: Int) -> TimeInterval {
        5 * pow(3, Double(max(n, 1) - 1))
    }
}

public enum DiskSpace {
    /// Below this a download doesn't start: merging and converting need room too.
    public static let reserveBytes: Int64 = 200 << 20

    /// Free bytes on the volume `path` is (or will be) on; nil when it can't be told.
    public static func free(at path: String) -> Int64? {
        var url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        while !fm.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Whether `needed` more bytes fit, leaving the reserve free.
    public static func hasRoom(free: Int64, needed: Int64 = 0) -> Bool { free - max(needed, 0) >= reserveBytes }
}

/// Finds downloads that are already in the list: same link and same choices.
public enum DownloadDuplicates {
    /// The link without what doesn't change the video: a fragment, a trailing slash, the scheme's case.
    public static func normalized(_ url: String) -> String {
        let canonical = UrlTools.canonical(url) ?? url
        guard var c = URLComponents(string: canonical.trimmingCharacters(in: .whitespacesAndNewlines)) else { return canonical }
        c.fragment = nil
        c.scheme = c.scheme?.lowercased()
        c.host = c.host?.lowercased()
        while c.path.count > 1, c.path.hasSuffix("/") { c.path.removeLast() }
        return c.string ?? canonical
    }

    private static func key(_ r: DownloadRequest) -> String {
        [normalized(r.url), r.mode, "\(r.maxHeight)", r.codec, r.container, r.audioFormat, r.dynamicRange].joined(separator: "|")
    }

    /// Of `requests`, those matching a download still in progress, and those matching a finished one whose file exists.
    public static func find(_ requests: [DownloadRequest], among records: [DownloadRecord],
                            fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> (active: Set<String>, completed: Set<String>) {
        var activeKeys = Set<String>()
        var completedKeys = Set<String>()
        for r in records {
            switch r.state {
            case .queued, .downloading, .processing, .paused: activeKeys.insert(key(r.request))
            case .completed: if let path = r.filePath, fileExists(path) { completedKeys.insert(key(r.request)) }
            case .failed, .canceled: break
            }
        }
        var active = Set<String>()
        var completed = Set<String>()
        for request in requests {
            if activeKeys.contains(key(request)) { active.insert(request.url) }
            else if completedKeys.contains(key(request)) { completed.insert(request.url) }
        }
        return (active, completed)
    }
}

/// The working files yt-dlp, aria2c and ffmpeg leave beside an unfinished download. Given its final path, recognises
/// them by name: only what belongs to this download and can't be a finished file of the user's.
public enum PartialFiles {
    private static let workSuffix = RX.make(#"(\.part(-Frag\d+(\.part)?)?|\.ytdl|\.aria2|\.temp(\.\w+)?)$"#)
    private static let streamFile = RX.make(#"^\.f[\w-]+\.\w+$"#)
    private static let thumbnails = ["webp", "jpg", "jpeg", "png"]

    /// "/a/Title [id].mp4" → "Title [id]".
    public static func stem(of path: String) -> String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }

    public static func isLeftover(_ name: String, finalPath: String, keepThumbnails: Bool = false) -> Bool {
        let stem = stem(of: finalPath)
        guard name.hasPrefix(stem + ".") || name.hasPrefix(stem + ".temp") else { return false }
        let rest = String(name.dropFirst(stem.count))
        if RX.firstGroups(workSuffix, in: rest) != nil { return true }
        if RX.firstGroups(streamFile, in: rest) != nil { return true }
        if !keepThumbnails, thumbnails.contains(String(rest.dropFirst())), name != (finalPath as NSString).lastPathComponent { return true }
        return false
    }

    /// Removes them; returns how many.
    @discardableResult
    public static func remove(finalPath: String, keepThumbnails: Bool = false) -> Int {
        let fm = FileManager.default
        let folder = (finalPath as NSString).deletingLastPathComponent
        var removed = 0
        for name in (try? fm.contentsOfDirectory(atPath: folder)) ?? []
        where isLeftover(name, finalPath: finalPath, keepThumbnails: keepThumbnails) {
            if (try? fm.removeItem(atPath: (folder as NSString).appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }
}

/// Takes what could identify or sign in the user out of text that goes to the log or a diagnostics file.
public enum Redact {
    private static let url = RX.make(#"\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\s"'<>]+"#)
    /// Query keys that only say which video it is. Other values can be access tokens (Xiaohongshu's xsec_token, signed
    /// CDN addresses) and are replaced.
    private static let safeQueryKeys: Set<String> = ["v", "list", "p", "index", "t", "modal_id", "fid", "vid"]

    public static func text(_ text: String) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in url.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += address(ns.substring(with: m.range))
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    public static func address(_ address: String) -> String {
        guard var c = URLComponents(string: address) else { return address }
        if c.user != nil || c.password != nil {
            c.user = "***"
            c.password = nil
        }
        c.queryItems = c.queryItems?.map { safeQueryKeys.contains($0.name) ? $0 : URLQueryItem(name: $0.name, value: "***") }
        return c.string ?? address
    }
}

/// Packs what helps with a problem report into a zip: logs, versions and settings, with the private parts taken out.
public enum Diagnostics {
    public static func report(appVersion: String, tools: [(name: String, version: String?, path: String?)]) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        var lines = ["VidFlow for Mac \(appVersion)", "macOS \(os), \(arch)", "", "Components:"]
        lines += tools.map { "  \($0.name): \($0.version ?? "not installed") \($0.path.map(Redact.text) ?? "")" }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func sanitizedSettings(_ s: AppSettings) -> AppSettings {
        var s = s
        s.proxy = Redact.address(s.proxy)
        s.downloadFolder = Redact.text(s.downloadFolder)
        s.cookiesFile = s.cookiesFile.isEmpty ? "" : "(set)"
        return s
    }

    public static func export(to destination: URL, report: String, settings: AppSettings) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("VidFlow-diagnostics-\(UUID().uuidString)", isDirectory: true)
        let root = work.appendingPathComponent("VidFlow-diagnostics", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        try report.write(to: root.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        try JSONFile.write(sanitizedSettings(settings), to: root.appendingPathComponent("settings.json"))
        for file in (try? fm.contentsOfDirectory(at: AppPaths.logsDir, includingPropertiesForKeys: nil)) ?? [] {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            try Redact.text(text).write(to: root.appendingPathComponent(file.lastPathComponent), atomically: true, encoding: .utf8)
        }
        try? fm.removeItem(at: destination)
        let result = try await ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", root.path, destination.path])
        guard result.code == 0 else { throw YtDlpError(result.stderr) }
    }
}

extension CookieVault {
    /// Reads Netscape cookie text back (see `toNetscape`).
    public static func parseNetscape(_ text: String) -> [CookieRecord] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = String(raw)
            let httpOnly = line.hasPrefix("#HttpOnly_")
            if httpOnly { line.removeFirst("#HttpOnly_".count) } else if line.hasPrefix("#") { return nil }
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7 else { return nil }
            return CookieRecord(domain: f[0], path: f[2], name: f[5], value: f[6...].joined(separator: "\t"), secure: f[3] == "TRUE",
                                httpOnly: httpOnly, expires: Int64(f[4]) ?? 0)
        }
    }
}
