import Foundation
import Security

public struct CookieRecord: Equatable, Sendable, Codable {
    public var domain: String
    public var path: String
    public var name: String
    public var value: String
    public var secure: Bool
    public var httpOnly: Bool
    public var expires: Int64

    public init(domain: String, path: String, name: String, value: String, secure: Bool, httpOnly: Bool, expires: Int64) {
        self.domain = domain
        self.path = path
        self.name = name
        self.value = value
        self.secure = secure
        self.httpOnly = httpOnly
        self.expires = expires
    }
}

/// Where the secret lives. The Keychain in the app; memory in tests.
public protocol SecretStore: Sendable {
    func read() -> Data?
    func write(_ data: Data?)
}

/// One generic password in the user's login Keychain.
public struct KeychainSecret: SecretStore {
    public var service = "com.magicherry.VidFlow"
    public var account = "cookies"

    public init() {}

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func read() -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status != errSecSuccess, status != errSecItemNotFound { Log.warn("Keychain read failed: \(status)") }
        return status == errSecSuccess ? out as? Data : nil
    }

    public func write(_ data: Data?) {
        guard let data else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            add[kSecAttrLabel as String] = "VidFlow sign-in"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess { Log.warn("Keychain write failed: \(status)") }
    }
}

public final class MemorySecret: SecretStore, @unchecked Sendable {
    private let value = Locked<Data?>(nil)
    public init() {}
    public func read() -> Data? { value.current }
    public func write(_ data: Data?) { value.current = data }
}

/// The sign-in cookies, in Netscape format for yt-dlp. They rest in the Keychain. yt-dlp can only read a file, so while
/// VidFlow runs a copy sits in a private (0700) temporary folder, readable by this user alone; it is removed at quit,
/// after keeping whatever yt-dlp refreshed in it.
public final class CookieVault: Sendable {
    /// Platforms with an in-app sign-in. The others work without an account.
    public static let signInPlatforms: [Platform] = [.bilibili, .youTube, .douyin]

    private let secret: SecretStore
    private let cache = Locked<String?>(nil)
    private let loaded = Locked(false)
    private let folder: URL

    public init(secret: SecretStore = KeychainSecret()) {
        self.secret = secret
        // The Keychain-backed vault is the app's one session; any other (tests) keeps out of its way.
        let name = secret is KeychainSecret ? "VidFlow-\(getuid())-session" : "VidFlow-session-\(UUID().uuidString)"
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
    }

    public static func domain(_ p: Platform) -> String {
        switch p {
        case .bilibili: "bilibili.com"
        case .douyin: "douyin.com"
        default: "youtube.com"
        }
    }

    /// Cookies that only exist while signed in.
    public static func sessionCookieNames(_ p: Platform) -> [String] {
        switch p {
        case .bilibili: ["SESSDATA"]
        case .douyin: ["sessionid", "sessionid_ss"]
        default: ["SAPISID", "__Secure-3PAPISID", "LOGIN_INFO"]
        }
    }

    private var text: String? {
        loaded.withLock { done in
            if !done {
                done = true
                cache.current = secret.read().map { String(decoding: $0, as: UTF8.self) }
            }
        }
        return cache.current
    }

    /// The stored cookies in Netscape form.
    public var storedText: String? { text }

    public var hasAnyLogin: Bool { Self.signInPlatforms.contains(where: isLoggedIn) }

    public func isLoggedIn(_ p: Platform) -> Bool {
        guard Self.signInPlatforms.contains(p), let text else { return false }
        return Self.isLoggedIn(p, netscape: text)
    }

    public static func isLoggedIn(_ p: Platform, netscape: String) -> Bool {
        let names = sessionCookieNames(p)
        let domain = domain(p)
        return netscape.split(whereSeparator: \.isNewline).contains { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            return f.count >= 7 && f[0].lowercased().hasSuffix(domain) && names.contains(String(f[5]))
        }
    }

    public static func toNetscape(_ cookies: [CookieRecord]) -> String {
        var out = "# Netscape HTTP Cookie File\n# Generated by VidFlow\n\n"
        var seen = Set<String>()
        for c in cookies where seen.insert("\(c.domain)\t\(c.path)\t\(c.name)").inserted {
            let prefix = c.httpOnly ? "#HttpOnly_" : ""
            let includeSub = c.domain.hasPrefix(".") ? "TRUE" : "FALSE"
            out += "\(prefix)\(c.domain)\t\(includeSub)\t\(c.path)\t\(c.secure ? "TRUE" : "FALSE")\t\(c.expires)\t\(c.name)\t\(c.value)\n"
        }
        return out
    }

    /// Replaces the stored cookies (after a sign-in or sign-out).
    public func store(_ cookies: [CookieRecord]) {
        let netscape = Self.toNetscape(cookies)
        let keep = Self.signInPlatforms.contains { Self.isLoggedIn($0, netscape: netscape) }
        loaded.current = true
        cache.current = keep ? netscape : nil
        secret.write(keep ? Data(netscape.utf8) : nil)
        removeSessionFile()
    }

    /// The cookie file to pass to yt-dlp, or nil when nobody is signed in.
    public func sessionFile() -> String? {
        guard hasAnyLogin, let text else { return nil }
        let file = folder.appendingPathComponent("cookies.txt")
        let fm = FileManager.default
        if !fm.fileExists(atPath: file.path) {
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                guard fm.createFile(atPath: file.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else { return nil }
            } catch {
                Log.warn("Cookie file could not be written: \(error.localizedDescription)")
                return nil
            }
        }
        return file.path
    }

    /// At quit (and at launch, in case the last run didn't get to): keeps what yt-dlp refreshed, removes the file.
    public func closeSession() {
        let file = folder.appendingPathComponent("cookies.txt")
        if let refreshed = try? String(contentsOf: file, encoding: .utf8), refreshed != text,
           Self.signInPlatforms.contains(where: { Self.isLoggedIn($0, netscape: refreshed) }) {
            cache.current = refreshed
            secret.write(Data(refreshed.utf8))
        }
        removeSessionFile()
    }

    private func removeSessionFile() { try? FileManager.default.removeItem(at: folder) }
}

public enum QRLoginState: Sendable, Equatable { case waiting, scanned, expired, success }

/// A login QR code: the link it encodes and the key used to ask about it.
public struct QRCodeInfo: Sendable, Equatable {
    public var url: String
    public var key: String
}

public struct QRPollResult: Sendable {
    public var state: QRLoginState
    public var cookies: [CookieRecord]
}

/// Bilibili's web QR login: get a code, show it, and ask every couple of seconds whether the Bilibili app has scanned
/// and confirmed it. On success the response sets the login cookies (SESSDATA, bili_jct, DedeUserID…).
public enum BilibiliQRLogin {
    private static let generateURL = URL(string: "https://passport.bilibili.com/x/passport-login/web/qrcode/generate")!
    private static let pollURL = "https://passport.bilibili.com/x/passport-login/web/qrcode/poll?qrcode_key="

    private static func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 15
        return req
    }

    public static func generate(http: HTTPClient = .shared) async throws -> QRCodeInfo {
        let (data, _) = try await http.data(for: request(generateURL))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = root["data"] as? [String: Any], let url = d["url"] as? String, let key = d["qrcode_key"] as? String else {
            throw URLError(.cannotParseResponse)
        }
        return QRCodeInfo(url: url, key: key)
    }

    public static func poll(key: String, http: HTTPClient = .shared) async throws -> QRPollResult {
        guard let encoded = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics), let url = URL(string: pollURL + encoded) else {
            throw URLError(.badURL)
        }
        let (data, resp) = try await http.data(for: request(url))
        let (state, redirect) = try parsePoll(data)
        guard state == .success else { return QRPollResult(state: state, cookies: []) }

        // The login cookies arrive as Set-Cookie headers on the successful poll.
        let headers = resp.allHeaderFields.reduce(into: [String: String]()) { out, kv in
            if let k = kv.key as? String, let v = kv.value as? String { out[k] = v }
        }
        var cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url).map { c in
            CookieRecord(domain: c.domain.hasPrefix(".") ? c.domain : "." + c.domain, path: c.path, name: c.name, value: c.value,
                         secure: c.isSecure, httpOnly: c.isHTTPOnly, expires: c.expiresDate.map { Int64($0.timeIntervalSince1970) } ?? 0)
        }
        // The redirect URL carries the same values; use it for anything the headers didn't set.
        for c in cookiesFromURL(redirect) where !cookies.contains(where: { $0.name == c.name }) { cookies.append(c) }
        return QRPollResult(state: .success, cookies: cookies)
    }

    /// The poll answer's inner code: 0 signed in, 86090 scanned (waiting for confirmation on the phone), 86038 expired,
    /// 86101 (and anything else) not scanned yet.
    public static func parsePoll(_ json: Data) throws -> (QRLoginState, String) {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let d = root["data"] as? [String: Any], let code = (d["code"] as? NSNumber)?.intValue else {
            throw URLError(.cannotParseResponse)
        }
        let state: QRLoginState = switch code {
        case 0: .success
        case 86090: .scanned
        case 86038: .expired
        default: .waiting
        }
        return (state, d["url"] as? String ?? "")
    }

    /// Login cookies from the success URL's query (DedeUserID, SESSDATA, bili_jct…), valid until its Expires.
    public static func cookiesFromURL(_ url: String) -> [CookieRecord] {
        guard let items = URLComponents(string: url)?.queryItems else { return [] }
        // Normally an absolute Unix time; a small number would be a lifetime in seconds.
        var expires: Int64 = 0
        if let e = items.first(where: { $0.name == "Expires" })?.value.flatMap({ Int64($0) }) {
            expires = e > 1_000_000_000 ? e : Int64(Date().timeIntervalSince1970) + e
        }
        return items.compactMap { item in
            guard ["DedeUserID", "DedeUserID__ckMd5", "SESSDATA", "bili_jct", "sid"].contains(item.name), let value = item.value else { return nil }
            return CookieRecord(domain: ".bilibili.com", path: "/", name: item.name, value: value, secure: false,
                                httpOnly: item.name == "SESSDATA", expires: expires)
        }
    }
}

/// Published next to each release as update-macos.json.
public struct UpdateManifest: Codable, Equatable, Sendable {
    public var version: String
    public var url: String
    public var sha256: String
    public var size: Int64
    public var notes: String
    public var published: Date?

    public init(version: String, url: String, sha256: String, size: Int64, notes: String = "", published: Date? = nil) {
        self.version = version
        self.url = url
        self.sha256 = sha256
        self.size = size
        self.notes = notes
        self.published = published
    }
}

public enum UpdateOutcome: Sendable, Equatable { case none, succeeded, failed }

/// App self-update: read the release manifest, download the archive (with retries), verify its size and SHA-256 and
/// that it is signed by the same developer, then swap it in once VidFlow has quit. A failed swap leaves the old app in
/// place; that is detected at the next start.
public enum UpdateService {
    /// VIDFLOW_UPDATE_MANIFEST overrides the source (an http(s) URL or a local file) for testing.
    public static var manifestSource: String {
        if let custom = ProcessInfo.processInfo.environment["VIDFLOW_UPDATE_MANIFEST"], !custom.isEmpty { return custom }
        return "https://github.com/Magicherry/VidFlow-for-Mac/releases/latest/download/update-macos.json"
    }

    public static func parseManifest(_ data: Data) throws -> UpdateManifest { try JSONFile.decoder().decode(UpdateManifest.self, from: data) }

    public static func fetchManifest(http: HTTPClient = .shared) async throws -> UpdateManifest {
        let source = manifestSource
        if source.hasPrefix("/") { return try parseManifest(Data(contentsOf: URL(fileURLWithPath: source))) }
        guard let url = URL(string: source) else { throw URLError(.badURL) }
        return try parseManifest(try await http.data(for: URLRequest(url: url)).0)
    }

    /// Compares dotted versions: 1.10.0 is newer than 1.9.9.
    public static func isNewer(_ version: String, than current: String) -> Bool {
        let isVersion = { (s: String) in !s.isEmpty && s.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { Int($0) != nil } }
        return isVersion(version) && isVersion(current) && version.compare(current, options: .numeric) == .orderedDescending
    }

    public static func archive(for m: UpdateManifest) -> URL {
        AppPaths.updatesDir.appendingPathComponent("VidFlow-\(m.version).zip")
    }

    /// Downloads (or reuses an already verified copy of) the update. Retries up to 3 times.
    public static func download(_ m: UpdateManifest, http: HTTPClient = .shared, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        try AppPaths.ensureDirectory(AppPaths.updatesDir)
        let file = archive(for: m)
        if verify(file, m) { return file }
        let tmp = file.appendingPathExtension("download")
        for attempt in 1...3 {
            do {
                if m.url.hasPrefix("/") {
                    try? FileManager.default.removeItem(at: tmp)
                    try FileManager.default.copyItem(atPath: m.url, toPath: tmp.path)
                } else {
                    guard let url = URL(string: m.url) else { throw URLError(.badURL) }
                    try await FileDownloader.download(from: url, to: tmp, http: http, progress: progress)
                }
                guard verify(tmp, m) else {
                    try? FileManager.default.removeItem(at: tmp)
                    throw YtDlpError(L.get("Update_ChecksumMismatch"))
                }
                try? FileManager.default.removeItem(at: file)
                try FileManager.default.moveItem(at: tmp, to: file)
                pruneOldArchives(keep: file)
                return file
            } catch {
                if error is CancellationError || attempt == 3 { throw error }
                Log.warn("Update download attempt \(attempt) failed: \(error.localizedDescription)")
                try await Task.sleep(for: .seconds(2 * attempt))
            }
        }
        throw YtDlpError(L.get("Update_DownloadFailed"))
    }

    /// Size and SHA-256 must both match the manifest.
    public static func verify(_ file: URL, _ m: UpdateManifest) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64,
              m.size <= 0 || size == m.size, let hash = try? FileDownloader.sha256(of: file) else { return false }
        return hash.caseInsensitiveCompare(m.sha256.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    /// Unpacks a verified archive and returns the VidFlow.app inside, once macOS confirms it is intact and signed by
    /// the same developer as the running app. The SHA-256 only says the file arrived as the manifest describes; this is
    /// what says it really comes from us. An ad-hoc signed development build can't vouch for anything, so it refuses.
    public static func unpack(_ archive: URL, runningApp: URL, allowUnsigned: Bool = false) async throws -> URL {
        let fm = FileManager.default
        let dest = AppPaths.updatesDir.appendingPathComponent("unpacked", isDirectory: true)
        try? fm.removeItem(at: dest)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let result = try await ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", archive.path, dest.path])
        guard result.code == 0 else { throw YtDlpError(result.stderr) }
        let app = dest.appendingPathComponent(runningApp.lastPathComponent)
        guard fm.fileExists(atPath: app.path) else { throw YtDlpError(L.format("Error_ZipMissing", runningApp.lastPathComponent)) }
        if !allowUnsigned, let problem = CodeIdentity.problem(candidate: app, running: runningApp) {
            throw YtDlpError(L.format("Update_BadSignature", problem))
        }
        return app
    }

    private static var pendingFile: URL { AppPaths.updatesDir.appendingPathComponent("pending.json") }

    private struct Pending: Codable { var version: String }

    /// Starts a small script that waits for VidFlow to exit, swaps the app, and (optionally) reopens it. The old app is
    /// kept until the new one is in place and is put back if the move fails. The caller must quit right after.
    public static func installAfterExit(newApp: URL, replacing app: URL, version: String, relaunch: Bool) throws {
        try JSONFile.write(Pending(version: version), to: pendingFile)
        let script = AppPaths.updatesDir.appendingPathComponent("install.sh")
        try swapScript.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [script.path, "\(ProcessInfo.processInfo.processIdentifier)", newApp.path, app.path, relaunch ? "1" : "0"]
        try task.run()
        Log.info("Update to \(version) will be installed after exit")
    }

    /// Arguments: pid of VidFlow, the new app, the app to replace, whether to relaunch.
    static let swapScript = #"""
    #!/bin/sh
    pid="$1"; new="$2"; app="$3"; relaunch="$4"
    old="$app.previous-$$"
    i=0
    while kill -0 "$pid" 2>/dev/null; do
        i=$((i + 1)); [ "$i" -gt 300 ] && exit 1
        sleep 0.1
    done
    if mv "$app" "$old"; then
        if mv "$new" "$app"; then
            rm -rf "$old"
        else
            mv "$old" "$app"
        fi
    fi
    [ "$relaunch" = 1 ] && /usr/bin/open "$app"
    exit 0
    """#

    /// Call at startup: did the last update install? (A failed swap leaves the old version running, which is how a
    /// failure shows up here.)
    public static func checkPendingResult(current: String) -> (outcome: UpdateOutcome, version: String?) {
        guard let data = try? Data(contentsOf: pendingFile) else { return (.none, nil) }
        try? FileManager.default.removeItem(at: pendingFile)
        guard let pending = try? JSONFile.decoder().decode(Pending.self, from: data) else { return (.none, nil) }
        let outcome: UpdateOutcome = isNewer(pending.version, than: current) ? .failed : .succeeded
        Log.info("Update to \(pending.version): \(outcome)")
        return (outcome, pending.version)
    }

    private static func pruneOldArchives(keep: URL) {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: AppPaths.updatesDir, includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "zip" && f.lastPathComponent != keep.lastPathComponent { try? fm.removeItem(at: f) }
    }
}

/// What macOS says about code signatures.
public enum CodeIdentity {
    /// The running app's team, or nil for an ad-hoc signed (development) build.
    public static func teamIdentifier(of app: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Why `candidate` shouldn't replace `running`, or nil if it may. Checks the whole bundle and requires it to satisfy
    /// a Developer ID requirement for the running app's own team.
    public static func problem(candidate: URL, running: URL) -> String? {
        guard let team = teamIdentifier(of: running) else { return L.get("Update_DevBuild") }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(candidate as CFURL, [], &code) == errSecSuccess, let code else { return "SecStaticCode" }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString
        guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess else { return "SecRequirement" }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        return status == errSecSuccess ? nil : "OSStatus \(status)"
    }
}
