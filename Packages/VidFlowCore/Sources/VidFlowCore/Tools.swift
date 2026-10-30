import Foundation

/// The external components VidFlow runs.
public enum Tool: String, CaseIterable, Identifiable, Sendable {
    case ytDlp = "yt-dlp", ffmpeg, deno = "Deno", aria2

    public var id: String { rawValue }

    /// File name on disk.
    public var executable: String {
        switch self {
        case .ytDlp: "yt-dlp"
        case .ffmpeg: "ffmpeg"
        case .deno: "deno"
        case .aria2: "aria2c"
        }
    }

    public var required: Bool { self == .ytDlp }
    public var purposeKey: String {
        switch self {
        case .ytDlp: "Tools_YtDlpPurpose"
        case .ffmpeg: "Tools_FfmpegPurpose"
        case .deno: "Tools_DenoPurpose"
        case .aria2: "Tools_Aria2Purpose"
        }
    }
    public var missingKey: String {
        switch self {
        case .ytDlp: "Settings_YtDlpMissing"
        case .ffmpeg: "Settings_FfmpegMissing"
        case .deno: "Settings_DenoMissing"
        case .aria2: "Settings_Aria2Missing"
        }
    }
    /// aria2 publishes no macOS builds, so VidFlow carries its own; it updates with the app.
    public var isBundled: Bool { self == .aria2 }
}

/// Locates, installs and updates the external tools (yt-dlp, ffmpeg, Deno; aria2 ships inside the app).
public struct ToolManager: Sendable {
    public var bundledHelpers: URL?
    public var http: HTTPClient
    /// Where ffmpeg normally comes from.
    public var ffmpegPrimary: String

    public init(bundledHelpers: URL? = nil, http: HTTPClient = .shared,
                ffmpegPrimary: String = "https://ffmpeg.martin-riedl.de/redirect/latest/macos/\(ToolManager.ffmpegArch)/snapshot") {
        self.bundledHelpers = bundledHelpers
        self.http = http
        self.ffmpegPrimary = ffmpegPrimary
    }

    #if arch(arm64)
    public static let ffmpegArch = "arm64"
    private static let fallbackArch = "arm64"
    private static let denoArch = "aarch64"
    #else
    public static let ffmpegArch = "amd64"
    private static let fallbackArch = "x64"
    private static let denoArch = "x86_64"
    #endif

    private static let ytDlpURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos.zip")!
    private static let ytDlpSums = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS")!
    private static let denoURL = URL(string: "https://github.com/denoland/deno/releases/latest/download/deno-\(denoArch)-apple-darwin.zip")!
    private func ffmpegURL(_ name: String) -> URL { URL(string: "\(ffmpegPrimary)/\(name).zip")! }
    /// Older but steady: used when the normal source can't be reached. The next update check moves back to the normal one.
    private static func ffmpegFallbackURL(_ name: String) -> URL {
        URL(string: "https://github.com/eugeneware/ffmpeg-static/releases/latest/download/\(name)-darwin-\(fallbackArch).gz")!
    }

    /// GUI apps don't inherit a shell's PATH, so the usual package manager folders are searched as well.
    static let searchFolders = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]

    /// VidFlow's own copy wins, then the one inside the app, then one the user installed themselves.
    public func path(_ tool: Tool) -> String? {
        let fm = FileManager.default
        var candidates = [AppPaths.binDir.appendingPathComponent(tool.executable).path]
        if let bundledHelpers { candidates.append(bundledHelpers.appendingPathComponent(tool.executable).path) }
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        for dir in path + Self.searchFolders { candidates.append((dir as NSString).appendingPathComponent(tool.executable)) }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    public func isManaged(_ path: String) -> Bool { path.hasPrefix(AppPaths.binDir.path) }
    public func isInsideApp(_ path: String) -> Bool {
        bundledHelpers.map { path.hasPrefix($0.path) } ?? false
    }

    private var ffmpegBuildFile: URL { AppPaths.binDir.appendingPathComponent("ffmpeg.build") }

    public var ffmpegDir: String? { path(.ffmpeg).map { ($0 as NSString).deletingLastPathComponent } }

    // ---- Versions ---------------------------------------------------------------------------------------------

    public func installedVersion(_ tool: Tool) async -> String? {
        guard let exe = path(tool) else { return nil }
        // VidFlow's ffmpeg doesn't say which snapshot it is; the build was noted when it was installed.
        if tool == .ffmpeg, isManaged(exe), let build = try? String(contentsOf: ffmpegBuildFile, encoding: .utf8) {
            return build.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let output = await ProcessRunner.capture(exe, [tool == .ffmpeg ? "-version" : "--version"])
        guard let line = output?.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) else { return nil }
        return Self.parseVersion(tool, line)
    }

    /// "ffmpeg version N-12345-g... Copyright ..." → "N-12345-g...", "deno 2.5.4 (…)" → "2.5.4", "aria2 version 1.37.0" → "1.37.0".
    public static func parseVersion(_ tool: Tool, _ line: String) -> String {
        switch tool {
        case .ffmpeg where line.hasPrefix("ffmpeg version "):
            String(line.dropFirst("ffmpeg version ".count).split(separator: " ").first ?? "")
        case .deno where line.hasPrefix("deno "):
            String(line.split(separator: " ")[1])
        case .aria2 where line.hasPrefix("aria2 version "):
            String(line.dropFirst("aria2 version ".count)).trimmingCharacters(in: .whitespaces)
        default: line
        }
    }

    /// The newest version available, or nil if unreachable. github.com/…/releases/latest redirects to …/tag/<version>;
    /// unlike the REST API this is not limited to 60 requests/hour per IP, which shared proxy exit IPs exhaust quickly.
    public func latestVersion(_ tool: Tool) async -> String? {
        do {
            switch tool {
            case .ytDlp:
                return Self.tag(from: try await http.finalURL(of: URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest")!))
            case .deno:
                return Self.tag(from: try await http.finalURL(of: URL(string: "https://github.com/denoland/deno/releases/latest")!))
                    .map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 }
            case .ffmpeg:
                // The redirect names the build: …/1792426763_N-127654-g7045cc9b80/ffmpeg.zip
                return Self.ffmpegBuild(fromPath: try await http.finalURL(of: ffmpegURL("ffmpeg"))?.path ?? "")
            case .aria2:
                return nil
            }
        } catch {
            Log.info("Latest \(tool.rawValue) check failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// ".../releases/tag/2026.10.21" → "2026.10.21".
    public static func tag(from url: URL?) -> String? {
        guard let path = url?.path, let r = path.range(of: "/releases/tag/") else { return nil }
        return String(path[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "/")).removingPercentEncoding
    }

    private static let ffmpegBuildRegex = RX.make(#"N-(\d+)"#)

    /// "/download/macos/arm64/1792426763_N-127654-g7045cc9b80/ffmpeg.zip" → "N-127654".
    public static func ffmpegBuild(fromPath path: String) -> String? {
        RX.firstGroups(ffmpegBuildRegex, in: path)?[1].map { "N-\($0)" }
    }

    /// True when `installed` is the same as or newer than `latest` (yt-dlp versions are dates like 2026.10.21,
    /// nightlies add a fourth part; ffmpeg snapshots count up as N-127654).
    public static func isUpToDate(_ tool: Tool, installed: String?, latest: String?) -> Bool {
        guard let installed = installed?.trimmingCharacters(in: .whitespacesAndNewlines),
              let latest = latest?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        if tool == .ffmpeg {
            guard let a = ffmpegBuild(fromPath: installed).flatMap({ Int($0.dropFirst(2)) }),
                  let b = ffmpegBuild(fromPath: latest).flatMap({ Int($0.dropFirst(2)) }) else { return installed == latest }
            return a >= b
        }
        let a = installed.split(separator: ".").map { Int($0) }
        let b = latest.split(separator: ".").map { Int($0) }
        guard !a.contains(nil), !b.contains(nil), !a.isEmpty, !b.isEmpty else {
            return installed.caseInsensitiveCompare(latest) == .orderedSame
        }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i]! : 0
            let y = i < b.count ? b[i]! : 0
            if x != y { return x > y }
        }
        return true
    }

    // ---- Installing -------------------------------------------------------------------------------------------

    public func install(_ tool: Tool, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try AppPaths.ensureDirectory(AppPaths.binDir)
        switch tool {
        case .ytDlp:
            try await installYtDlp(progress: progress)
        case .deno:
            try await installZipped(from: Self.denoURL, contains: ["deno"], sumsURL: URL(string: Self.denoURL.absoluteString + ".sha256sum"), progress: progress)
        case .ffmpeg:
            do {
                try await installFfmpegFromPrimary(progress: progress)
            } catch {
                if error is CancellationError { throw error }
                Log.warn("ffmpeg's usual source failed, using the fallback: \(error.localizedDescription)")
                try await installFfmpegFromFallback(progress: progress)
            }
        case .aria2:
            break
        }
    }

    /// The folder build, not the single-file one: that unpacks itself at every start, about 10 s here against 0.3 s.
    /// A link at bin/yt-dlp points at the program inside the folder.
    private func installYtDlp(progress: (@Sendable (Double) -> Void)?) async throws {
        let fm = FileManager.default
        let zip = AppPaths.binDir.appendingPathComponent("yt-dlp.zip.download")
        let unpacked = AppPaths.binDir.appendingPathComponent("yt-dlp.dist.new", isDirectory: true)
        let dist = AppPaths.binDir.appendingPathComponent("yt-dlp.dist", isDirectory: true)
        let link = AppPaths.binDir.appendingPathComponent(Tool.ytDlp.executable)
        defer {
            try? fm.removeItem(at: zip)
            try? fm.removeItem(at: unpacked)
        }
        try await FileDownloader.download(from: Self.ytDlpURL, to: zip, http: http, progress: progress)
        try await verify(zip, sumsURL: Self.ytDlpSums, name: "yt-dlp_macos.zip")
        try? fm.removeItem(at: unpacked)
        let result = try await ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        guard result.code == 0 else { throw YtDlpError(result.stderr) }
        guard fm.isExecutableFile(atPath: unpacked.appendingPathComponent("yt-dlp_macos").path) else {
            throw YtDlpError(L.format("Error_ZipMissing", "yt-dlp_macos"))
        }
        try? fm.removeItem(at: dist)
        try fm.moveItem(at: unpacked, to: dist)
        try? fm.removeItem(at: link)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "yt-dlp.dist/yt-dlp_macos")
    }

    /// Two archives of about the same size: each is half of the progress.
    private func installFfmpegFromPrimary(progress: (@Sendable (Double) -> Void)?) async throws {
        try await installZipped(from: ffmpegURL("ffmpeg"), contains: ["ffmpeg"], sumsURL: try await ffmpegSums("ffmpeg")) { progress?($0 / 2) }
        try await installZipped(from: ffmpegURL("ffprobe"), contains: ["ffprobe"], sumsURL: try await ffmpegSums("ffprobe")) { progress?(50 + $0 / 2) }
        try? await latestVersion(.ffmpeg)?.write(to: ffmpegBuildFile, atomically: true, encoding: .utf8)
    }

    private func installFfmpegFromFallback(progress: (@Sendable (Double) -> Void)?) async throws {
        let fm = FileManager.default
        let work = AppPaths.binDir.appendingPathComponent("install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        for (i, name) in ["ffmpeg", "ffprobe"].enumerated() {
            let gz = work.appendingPathComponent("\(name).gz")
            try await FileDownloader.download(from: Self.ffmpegFallbackURL(name), to: gz, http: http) { progress?(Double(i) * 50 + $0 / 2) }
            let result = try await ProcessRunner.run("/usr/bin/gunzip", ["-f", gz.path])
            guard result.code == 0 else { throw YtDlpError(result.stderr) }
            try place(work.appendingPathComponent(name), as: name)
        }
        // It reports its own version from now on, which never counts as current: the next check goes back to the usual source.
        try? fm.removeItem(at: ffmpegBuildFile)
    }

    /// The checksum sits beside the build the "latest" address redirects to, not beside the redirect.
    private func ffmpegSums(_ name: String) async throws -> URL? {
        try await http.finalURL(of: ffmpegURL(name)).flatMap { URL(string: $0.absoluteString + ".sha256") }
    }

    private func installZipped(from url: URL, contains names: [String], sumsURL: URL?,
                               progress: (@Sendable (Double) -> Void)?) async throws {
        let fm = FileManager.default
        let work = AppPaths.binDir.appendingPathComponent("install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let zip = work.appendingPathComponent("archive.zip")
        try await FileDownloader.download(from: url, to: zip, http: http, progress: progress)
        if let sumsURL { try await verify(zip, sumsURL: sumsURL, name: url.lastPathComponent) }

        let result = try await ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        guard result.code == 0 else { throw YtDlpError(result.stderr) }
        for name in names {
            guard let found = fm.enumerator(at: work, includingPropertiesForKeys: nil)?
                .compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == name }) else {
                throw YtDlpError(L.format("Error_ZipMissing", name))
            }
            try place(found, as: name)
        }
    }

    /// Compares with the published checksum. A release that publishes none, or a list that can't be fetched, doesn't
    /// stop the install (the download itself came over HTTPS); a checksum that differs does.
    private func verify(_ file: URL, sumsURL: URL, name: String) async throws {
        guard let text = try? await http.string(from: sumsURL) else {
            Log.info("No checksum available for \(name)")
            return
        }
        guard let expected = Self.checksum(in: text, for: name) else { return }
        guard try FileDownloader.sha256(of: file) == expected else { throw YtDlpError(L.get("Update_ChecksumMismatch")) }
    }

    /// A checksum file is either one bare hash, or lines of "hash  name".
    public static func checksum(in text: String, for name: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        let isHash = { (s: String) in s.count == 64 && s.allSatisfy(\.isHexDigit) }
        if let line = lines.first(where: { $0.count >= 2 && $0.last?.hasSuffix(name) == true && isHash($0[0]) }) {
            return line[0].lowercased()
        }
        if lines.count == 1, let only = lines[0].first, isHash(only) { return only.lowercased() }
        return nil
    }

    private func place(_ file: URL, as name: String) throws {
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        // Swapped in by rename: a tool still running keeps its old file, a new start gets the new one.
        let dest = AppPaths.binDir.appendingPathComponent(name)
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: file)
        } else {
            try fm.moveItem(at: file, to: dest)
        }
        removexattr(dest.path, "com.apple.quarantine", 0)
    }
}

/// Runs yt-dlp. Argument building and output parsing live in `YtDlpArgs` / `YtDlpOutputParser`.
public struct YtDlpService: Sendable {
    public var tools: ToolManager
    public var vault: CookieVault
    public var http: HTTPClient
    /// Douyin: given douyin.com/video/ID, returns the JSON of its "aweme/detail" API. Douyin signs those requests in
    /// page script (which yt-dlp can't do), so the app loads the page in a hidden WKWebView and reads the answer.
    public var fetchDouyinDetail: (@Sendable (String) async throws -> String)?
    /// Called when browser cookies could not be read and were skipped.
    public var onBrowserCookiesFailed: (@Sendable () -> Void)?

    private static let douyinReferer = "https://www.douyin.com/"
    /// The browser whose cookies failed to read this session (reset when the setting changes).
    private static let unreadableBrowser = Locked<String?>(nil)

    private var settings: AppSettings { SettingsStore.shared.current }

    public init(tools: ToolManager, vault: CookieVault, http: HTTPClient = .shared,
                fetchDouyinDetail: (@Sendable (String) async throws -> String)? = nil,
                onBrowserCookiesFailed: (@Sendable () -> Void)? = nil) {
        self.tools = tools
        self.vault = vault
        self.http = http
        self.fetchDouyinDetail = fetchDouyinDetail
        self.onBrowserCookiesFailed = onBrowserCookiesFailed
    }

    private func douyin(_ url: String) async throws -> DouyinVideo {
        guard let fetchDouyinDetail else { throw YtDlpError(L.get("Error_DouyinUnavailable")) }
        guard UrlTools.canonicalDouyinURL(url) != nil else { throw YtDlpError(L.get("Error_DouyinNotVideo")) }
        return try DouyinParser.parse(try await fetchDouyinDetail(url))
    }

    public func info(url input: String) async throws -> MediaInfo {
        let url = try await ShortLinks.normalize(input, http: http)
        if UrlTools.detectPlatform(url) == .douyin { return .video(DouyinParser.toVideoInfo(try await douyin(url))) }
        let settings = self.settings
        let stdout = Locked<[String]>([])
        let result = try await runWithCookieFallback(url: url, buildArgs: { env in
            stdout.current = []
            return YtDlpArgs.info(url: url, settings: settings, env: env)
        }, onLine: { line in stdout.withLock { $0.append(line) } })
        if result.code != 0 { throw YtDlpError(ErrorMapper.friendly(result.stderr), detail: result.stderr) }

        let info = try InfoParser.parse(stdout.current.joined(separator: "\n"), requestedURL: url)
        if case .playlist(let p) = info {
            if p.entries.isEmpty { throw YtDlpError(L.get("Error_EmptyPlaylist")) }
            if p.platform == .bilibili { return .playlist(try await BilibiliApi.enrich(p, http: http)) }
        }
        return info
    }

    /// Runs the download, reporting events as they happen. Returns the final file path when yt-dlp reports one.
    public func download(_ input: DownloadRequest, onEvent: @escaping @Sendable (DownloadEvent) -> Void) async throws -> String? {
        var req = input
        if req.isAudio, tools.path(.ffmpeg) == nil { throw YtDlpError(L.get("Error_AudioNeedsFfmpeg")) }
        req.url = try await ShortLinks.normalize(req.url, http: http)
        try AppPaths.ensureDirectory(URL(fileURLWithPath: req.outputFolder))
        let settings = self.settings

        let filePath = Locked<String?>(nil)
        let parser = Locked(YtDlpOutputParser())
        let onLine: @Sendable (String) -> Void = { line in
            guard let event = parser.withLock({ $0.feed(line) }) else { return }
            if case .file(let path) = event { filePath.current = path }
            onEvent(event)
        }

        let result: ProcessResult
        if UrlTools.detectPlatform(req.url) == .douyin {
            // Stream addresses expire, so look them up again right before downloading (also after a restart).
            let video = try await douyin(req.url)
            let stream = DouyinParser.pick(video, maxHeight: req.maxHeight, codec: req.codec)
            let date = Format.date(video.uploadDate)
            let known: [String: String?] = [
                "title": video.title,
                "uploader": video.author ?? "Unknown",
                "date": date ?? "unknown",
                "year": date.map { String($0.prefix(4)) } ?? "unknown",
                "month": date.map { String($0.dropFirst(5).prefix(2)) } ?? "00",
                "resolution": req.isCover ? "cover" : req.isAudio ? "audio" : "\(stream.resolution)p",
                "id": video.id,
            ]
            // The media host needs no cookies; only the Referer.
            let env = YtDlpArgs.Environment(ffmpegDir: tools.ffmpegDir, skipBrowserCookies: true)
            // The cover is a plain image address too, downloaded the same way.
            guard let media = req.isCover ? video.cover : stream.url else { throw YtDlpError(L.get("Error_NoCover")) }
            let direct = YtDlpArgs.DirectMedia(url: media, referer: Self.douyinReferer, known: known)
            var page = req
            page.url = "https://www.douyin.com/video/\(video.id)"
            result = try await run(YtDlpArgs.download(page, settings: settings, env: env, direct: direct), onLine: onLine)
        } else {
            if req.isAudio, req.audioOutputFormat == MediaFeatures.original {
                req.audioFormat = try await originalAudioFormat(req, settings)
            }
            let final = req
            result = try await runWithCookieFallback(url: req.url, buildArgs: { env in
                YtDlpArgs.download(final, settings: settings, env: env)
            }, onLine: onLine, accelerate: true)
        }
        try Task.checkCancellation()
        if result.code != 0 { throw YtDlpError(ErrorMapper.friendly(result.stderr), detail: result.stderr) }
        return filePath.current
    }

    /// "Original" audio: which codec the track has decides the file type (Hi-Res FLAC → .flac). Falls back to yt-dlp's
    /// "best" if the question can't be answered.
    private func originalAudioFormat(_ req: DownloadRequest, _ settings: AppSettings) async throws -> String {
        let codec = Locked<String?>(nil)
        let result = try await runWithCookieFallback(url: req.url, buildArgs: { env in
            YtDlpArgs.probeAudio(req, settings: settings, env: env)
        }, onLine: { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            codec.withLock { if $0 == nil, !t.isEmpty { $0 = t } }
        })
        let format = result.code == 0 ? MediaFeatures.originalOutput(codec.current) : MediaFeatures.original
        Log.info("Original audio: \(codec.current ?? "?") -> \(format)")
        return format
    }

    /// Runs yt-dlp with cookie fallbacks:
    /// - If the configured browser's cookies can't be read, retry without them and skip them for the rest of the session.
    /// - YouTube: signed-in requests often come back with no downloadable formats (YouTube treats them differently, and
    ///   exported cookies get rotated), so try without the in-app login first and only use it when YouTube says sign-in
    ///   is needed (age / members-only / bot check). Bilibili always uses the login.
    private func runWithCookieFallback(url: String, buildArgs: (YtDlpArgs.Environment) -> [String],
                                       onLine: @escaping @Sendable (String) -> Void, accelerate: Bool = false) async throws -> ProcessResult {
        let settings = self.settings
        let browser = settings.cookiesBrowser
        let loginFile = vault.sessionFile()
        let youTubeLogin = loginFile != nil && UrlTools.detectPlatform(url) == .youTube && vault.isLoggedIn(.youTube)
        var env = YtDlpArgs.Environment(ffmpegDir: tools.ffmpegDir, loginCookieFile: loginFile,
                                        skipBrowserCookies: Self.unreadableBrowser.current == browser,
                                        skipLoginCookies: youTubeLogin, denoPath: tools.path(.deno))
        if accelerate { env = accelerated(env, url: url, settings: settings) }

        var result = try await run(buildArgs(env), onLine: onLine)

        if result.code != 0, !env.skipBrowserCookies, YtDlpArgs.usesBrowserCookies(settings), ErrorMapper.isCookieReadError(result.stderr) {
            Log.warn("Browser cookies unreadable, skipping them this session: \(ErrorMapper.lastErrorLine(result.stderr))")
            Self.unreadableBrowser.current = browser
            onBrowserCookiesFailed?()
            env.skipBrowserCookies = true
            result = try await run(buildArgs(env), onLine: onLine)
        }

        if result.code != 0, youTubeLogin, env.skipLoginCookies, ErrorMapper.needsSignIn(result.stderr) {
            Log.info("YouTube needs sign-in, retrying with the in-app login: \(ErrorMapper.lastErrorLine(result.stderr))")
            env.skipLoginCookies = false
            result = try await run(buildArgs(env), onLine: onLine)
        }

        // aria2c can trip over what yt-dlp's own downloader copes with (a host refusing parallel connections, an
        // unusual proxy): fall back to one connection rather than fail.
        if result.code != 0, env.aria2Path != nil, ErrorMapper.isAria2Failure(result.stderr) {
            Log.warn("aria2c failed, retrying with yt-dlp's own downloader: \(ErrorMapper.lastErrorLine(result.stderr))")
            env.aria2Path = nil
            result = try await run(buildArgs(env), onLine: onLine)
        }
        return result
    }

    /// Adds aria2 (when available and switched on) and the proxy the system would use. Not for the Chinese platforms:
    /// their CDNs are fast on one connection, and some of Bilibili's nodes answer a burst of connections with 503.
    private func accelerated(_ env: YtDlpArgs.Environment, url: String, settings: AppSettings) -> YtDlpArgs.Environment {
        guard settings.multiConnection, let aria2 = tools.path(.aria2) else { return env }
        if [.bilibili, .douyin, .weibo, .xiaohongshu].contains(UrlTools.detectPlatform(url)) { return env }
        var env = env
        env.aria2Path = aria2
        env.systemProxy = HTTPClient.systemProxy()
        return env
    }

    private func run(_ args: [String], onLine: @escaping @Sendable (String) -> Void) async throws -> ProcessResult {
        guard let exe = tools.path(.ytDlp) else { throw YtDlpError(L.get("Error_NoYtDlp")) }
        Log.info("yt-dlp " + args.map { $0.contains(" ") || $0.contains("|") ? "\"\($0)\"" : $0 }.joined(separator: " "))
        let result = try await ProcessRunner.run(exe, args, environment: ["PYTHONIOENCODING": "utf-8", "PYTHONUTF8": "1"], onLine: onLine)
        if result.code != 0 { Log.warn("yt-dlp exited \(result.code): \(ErrorMapper.lastErrorLine(result.stderr))") }
        return result
    }
}
