import Foundation
import Testing
@testable import VidFlowCore

private func cookie(_ name: String, _ value: String = "v", domain: String = ".bilibili.com", httpOnly: Bool = true) -> CookieRecord {
    CookieRecord(domain: domain, path: "/", name: name, value: value, secure: true, httpOnly: httpOnly, expires: 1900000000)
}

extension VidFlowCoreTests {
    @Suite("Netscape cookies")
    struct NetscapeTests {
        @Test func netscapeCookiesMarkHttpOnlyAndDedupe() {
            let text = CookieVault.toNetscape([
                CookieRecord(domain: ".bilibili.com", path: "/", name: "SESSDATA", value: "v", secure: true, httpOnly: true, expires: 1900000000),
                CookieRecord(domain: ".bilibili.com", path: "/", name: "SESSDATA", value: "dup", secure: true, httpOnly: true, expires: 1900000000),
            ])
            let lines = text.components(separatedBy: "\n").filter { $0.contains("SESSDATA") }
            #expect(lines.count == 1)
            #expect(lines[0].hasPrefix("#HttpOnly_.bilibili.com\tTRUE\t/\tTRUE\t1900000000\tSESSDATA\tv"))
        }

        @Test func hostOnlyCookiesAreNotMarkedAsSubdomainWide() {
            let text = CookieVault.toNetscape([CookieRecord(domain: "www.example.com", path: "/", name: "a", value: "b", secure: false, httpOnly: false, expires: 0)])
            #expect(text.contains("\nwww.example.com\tFALSE\t/\tFALSE\t0\ta\tb\n"))
            #expect(text.hasPrefix("# Netscape HTTP Cookie File\n"))
        }
    }

    @Suite("Bilibili QR login")
    struct BilibiliQrLoginTests {
        @Test(arguments: [(86101, QRLoginState.waiting), (86090, QRLoginState.scanned), (86038, QRLoginState.expired), (0, QRLoginState.success)])
        func pollCodesMapToStates(code: Int, expected: QRLoginState) throws {
            let json = #"{"code":0,"message":"OK","data":{"url":"","refresh_token":"","timestamp":0,"code":"# + "\(code)" + #","message":""}}"#
            #expect(try BilibiliQRLogin.parsePoll(Data(json.utf8)).0 == expected)
        }

        @Test func malformedPollAnswerThrows() {
            #expect(throws: (any Error).self) { try BilibiliQRLogin.parsePoll(Data(#"{"code":0}"#.utf8)) }
        }

        @Test func successUrlBecomesLoginCookies() throws {
            let url = "https://passport.biligame.com/x/passport-login/web/crossDomain?DedeUserID=123&DedeUserID__ckMd5=abc"
                + "&Expires=1893456000&SESSDATA=s%2C1893456000%2Cxyz&bili_jct=jct&gourl=https%3A%2F%2Fwww.bilibili.com"
            let cookies = BilibiliQRLogin.cookiesFromURL(url)
            #expect(cookies.map(\.name) == ["DedeUserID", "DedeUserID__ckMd5", "SESSDATA", "bili_jct"])
            let sess = try #require(cookies.first { $0.name == "SESSDATA" })
            #expect(sess.value == "s,1893456000,xyz")
            #expect(sess.domain == ".bilibili.com")
            #expect(sess.httpOnly)
            #expect(sess.expires == 1893456000)

            // Written out, it counts as signed in to Bilibili.
            let line = try #require(CookieVault.toNetscape(cookies).components(separatedBy: "\n").first { $0.contains("SESSDATA") })
            #expect(line.hasPrefix("#HttpOnly_.bilibili.com\tTRUE\t/\t"))
            #expect(CookieVault.isLoggedIn(.bilibili, netscape: CookieVault.toNetscape(cookies)))
        }

        @Test func nonLoginUrlGivesNoCookies() {
            #expect(BilibiliQRLogin.cookiesFromURL("").isEmpty)
        }

        @Test func smallExpiresIsALifetimeInSeconds() throws {
            let before = Int64(Date().timeIntervalSince1970)
            let c = try #require(BilibiliQRLogin.cookiesFromURL("https://x/?SESSDATA=s&Expires=3600").first)
            #expect(c.expires >= before + 3600)
            #expect(c.expires <= Int64(Date().timeIntervalSince1970) + 3600)
        }
    }

    @Suite("CookieVault")
    struct CookieVaultTests {
        init() { TestEnv.prepare() }

        static func netscape(_ cookies: [CookieRecord]) -> String { CookieVault.toNetscape(cookies) }
        static func text(_ secret: MemorySecret) -> String? { secret.read().map { String(decoding: $0, as: UTF8.self) } }

        // The session folder lives in the temp directory under a fixed name, so every test starts with store() (which
        // clears it) and ends with closeSession().

        @Test func storeMakesThePlatformSignedIn() {
            let secret = MemorySecret()
            let vault = CookieVault(secret: secret)
            defer { vault.closeSession() }
            #expect(!vault.isLoggedIn(.bilibili))
            #expect(!vault.hasAnyLogin)

            vault.store([cookie("SESSDATA"), cookie("bili_jct")])
            #expect(vault.isLoggedIn(.bilibili))
            #expect(!vault.isLoggedIn(.youTube))
            #expect(!vault.isLoggedIn(.douyin))
            #expect(!vault.isLoggedIn(.weibo)) // no in-app sign-in
            #expect(vault.hasAnyLogin)
            #expect(Self.text(secret)?.contains("SESSDATA\tv") == true)
        }

        @Test func cookiesWithoutASessionAreNotKept() {
            let secret = MemorySecret()
            let vault = CookieVault(secret: secret)
            defer { vault.closeSession() }
            vault.store([cookie("bili_jct"), cookie("DedeUserID")])
            #expect(!vault.isLoggedIn(.bilibili))
            #expect(secret.read() == nil)
        }

        @Test func storingNothingSignsOut() {
            let secret = MemorySecret()
            let vault = CookieVault(secret: secret)
            defer { vault.closeSession() }
            vault.store([cookie("SESSDATA")])
            #expect(vault.sessionFile() != nil)
            vault.store([])
            #expect(!vault.isLoggedIn(.bilibili))
            #expect(secret.read() == nil)
            #expect(vault.sessionFile() == nil)
        }

        @Test func aNewVaultReadsWhatTheSecretHolds() {
            let secret = MemorySecret()
            secret.write(Data(Self.netscape([cookie("sessionid", domain: ".douyin.com")]).utf8))
            let vault = CookieVault(secret: secret)
            defer { vault.closeSession() }
            #expect(vault.isLoggedIn(.douyin))
            #expect(!vault.isLoggedIn(.bilibili))
        }

        @Test func sessionCookiesAreRecognisedPerPlatform() {
            #expect(CookieVault.isLoggedIn(.bilibili, netscape: Self.netscape([cookie("SESSDATA")])))
            #expect(CookieVault.isLoggedIn(.douyin, netscape: Self.netscape([cookie("sessionid_ss", domain: ".douyin.com")])))
            #expect(CookieVault.isLoggedIn(.youTube, netscape: Self.netscape([cookie("SAPISID", domain: ".youtube.com")])))
            // Wrong domain or a cookie that exists without a sign-in.
            #expect(!CookieVault.isLoggedIn(.bilibili, netscape: Self.netscape([cookie("SESSDATA", domain: ".example.com")])))
            #expect(!CookieVault.isLoggedIn(.bilibili, netscape: Self.netscape([cookie("buvid3")])))
            #expect(!CookieVault.isLoggedIn(.bilibili, netscape: ""))
        }

        @Test func sessionFileIsPrivateToTheUser() throws {
            let secret = MemorySecret()
            let vault = CookieVault(secret: secret)
            defer { vault.closeSession() }
            #expect(vault.sessionFile() == nil) // nobody is signed in

            vault.store([cookie("SESSDATA")])
            let path = try #require(vault.sessionFile())
            let fm = FileManager.default
            let file = try fm.attributesOfItem(atPath: path)
            #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            let folder = try fm.attributesOfItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path)
            #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            #expect(try String(contentsOfFile: path, encoding: .utf8) == Self.netscape([cookie("SESSDATA")]))
            #expect(vault.sessionFile() == path) // reused while it exists
        }

        @Test func closeSessionKeepsWhatYtDlpRefreshedAndRemovesTheFile() throws {
            let secret = MemorySecret()
            let vault = CookieVault(secret: secret)
            defer { vault.closeSession() }
            vault.store([cookie("SESSDATA", "old")])
            let path = try #require(vault.sessionFile())

            // yt-dlp rewrites the file with a refreshed session.
            try Self.netscape([cookie("SESSDATA", "new")]).write(toFile: path, atomically: true, encoding: .utf8)
            vault.closeSession()

            #expect(Self.text(secret)?.contains("SESSDATA\tnew") == true)
            #expect(!FileManager.default.fileExists(atPath: path))
            #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path))
            // The next session starts from the refreshed cookies.
            let next = try #require(vault.sessionFile())
            #expect(try String(contentsOfFile: next, encoding: .utf8).contains("SESSDATA\tnew"))
        }

        @Test func closeSessionIgnoresARefreshedFileWithoutALogin() throws {
            let secret = MemorySecret()
            let vault = CookieVault(secret: secret)
            defer { vault.closeSession() }
            vault.store([cookie("SESSDATA", "keep")])
            let path = try #require(vault.sessionFile())
            try Self.netscape([cookie("buvid3")]).write(toFile: path, atomically: true, encoding: .utf8)
            vault.closeSession()
            #expect(Self.text(secret)?.contains("SESSDATA\tkeep") == true)
            #expect(vault.isLoggedIn(.bilibili))
            #expect(!FileManager.default.fileExists(atPath: path))
        }

        @Test func closeSessionWithoutAFileChangesNothing() {
            let secret = MemorySecret()
            let vault = CookieVault(secret: secret)
            vault.store([cookie("SESSDATA")])
            let before = secret.read()
            vault.closeSession()
            #expect(secret.read() == before)
        }
    }
}
