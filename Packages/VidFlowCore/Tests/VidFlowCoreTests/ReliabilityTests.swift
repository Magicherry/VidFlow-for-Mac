import Foundation
import Testing
@testable import VidFlowCore

@Suite("Reliability")
struct ReliabilityTests {
    @Test func transientFailuresAreToldApart() {
        for e in ["ERROR: [youtube] x: Unable to download webpage: The read operation timed out",
                  "ERROR: [download] Got error: Connection reset by peer", "ERROR: unable to download video data: HTTP Error 503: Service Unavailable",
                  "ERROR: [youtube] x: HTTP Error 429: Too Many Requests", "ERROR: Tunnel connection failed: 502 Bad Gateway"] {
            #expect(ErrorMapper.isTransient(e), "\(e)")
        }
        for e in ["ERROR: [youtube] x: Video unavailable", "ERROR: Unsupported URL: https://a.b", "ERROR: [youtube] x: Private video. Sign in",
                  "ERROR: [youtube] x: Requested format is not available", "ERROR: [Errno 28] No space left on device", ""] {
            #expect(!ErrorMapper.isTransient(e), "\(e)")
        }
    }

    @Test func diskFullIsRecognised() {
        #expect(ErrorMapper.isDiskFull("ERROR: unable to write data: [Errno 28] No space left on device"))
        #expect(!ErrorMapper.isDiskFull("ERROR: HTTP Error 404"))
    }

    @Test func backoffGrows() {
        #expect(RetryPolicy.delay(attempt: 1) == 5)
        #expect(RetryPolicy.delay(attempt: 2) == 15)
        #expect(RetryPolicy.delay(attempt: 3) == 45)
    }

    @Test func diskRoomKeepsTheReserve() {
        #expect(DiskSpace.hasRoom(free: DiskSpace.reserveBytes))
        #expect(!DiskSpace.hasRoom(free: DiskSpace.reserveBytes - 1))
        #expect(!DiskSpace.hasRoom(free: DiskSpace.reserveBytes + 10, needed: 11))
        #expect(DiskSpace.free(at: "/nonexistent/deep/folder") != nil)
    }

    private func request(_ url: String, height: Int = 0) -> DownloadRequest {
        DownloadRequest(url: url, mode: "video", maxHeight: height, writeSubtitles: false, outputFolder: "/tmp")
    }

    private func record(_ r: DownloadRequest, _ state: DownloadState, file: String? = nil) -> DownloadRecord {
        var rec = DownloadRecord(request: r, title: "t")
        rec.state = state
        rec.filePath = file
        return rec
    }

    @Test func duplicatesMatchLinkAndChoices() {
        let url = "https://www.youtube.com/watch?v=abc"
        let existing = [record(request(url), .completed, file: "/x.mp4"), record(request("https://x.com/a/status/1"), .downloading),
                        record(request("https://b.com/gone"), .completed, file: "/gone.mp4"), record(request("https://c.com/f"), .failed)]
        let found = DownloadDuplicates.find(
            [request(url + "#t"), request(url, height: 720), request("https://x.com/a/status/1/"), request("https://b.com/gone"), request("https://c.com/f")],
            among: existing, fileExists: { $0 == "/x.mp4" })
        #expect(found.completed == [url + "#t"])
        #expect(found.active == ["https://x.com/a/status/1/"])
    }

    @Test func leftoversAreRecognisedWithoutTouchingOtherFiles() {
        let final = "/d/Me [id].mp4"
        for name in ["Me [id].mp4.part", "Me [id].f229-hls.mp4.part", "Me [id].f229-hls.mp4.part-Frag12", "Me [id].f229-hls.mp4.part-Frag12.part",
                     "Me [id].mp4.ytdl", "Me [id].f137.mp4.aria2", "Me [id].f137.mp4", "Me [id].temp.mp4", "Me [id].webp"] {
            #expect(PartialFiles.isLeftover(name, finalPath: final), "\(name)")
        }
        for name in ["Me [id].mp4", "Me [id].srt", "Me [id].en.vtt", "Me [id] 2.mp4", "Other.mp4.part", "Me [id].mkv"] {
            #expect(!PartialFiles.isLeftover(name, finalPath: final), "\(name)")
        }
        #expect(!PartialFiles.isLeftover("Me [id].jpg", finalPath: "/d/Me [id].jpg"))
        #expect(!PartialFiles.isLeftover("Me [id].webp", finalPath: final, keepThumbnails: true))
    }

    @Test func removingLeftoversLeavesTheRest() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for n in ["A.mp4.part", "A.f1.mp4.part-Frag1", "A.mp4", "B.mp4.part"] { try Data().write(to: dir.appendingPathComponent(n)) }
        #expect(PartialFiles.remove(finalPath: dir.appendingPathComponent("A.mp4").path) == 2)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)) == ["A.mp4", "B.mp4.part"])
    }

    @Test func redactionTakesOutTokensAndPasswords() {
        #expect(Redact.address("http://user:secret@127.0.0.1:7890") == "http://***@127.0.0.1:7890")
        let text = Redact.text("yt-dlp --proxy socks5://u:p@h:1 https://www.xiaohongshu.com/explore/1?xsec_token=ABC&xsec_source=x https://www.youtube.com/watch?v=abc")
        #expect(!text.contains("ABC"))
        #expect(!text.contains("u:p"))
        #expect(text.contains("watch?v=abc"))
        #expect(Redact.text(FileManager.default.homeDirectoryForCurrentUser.path + "/a") == "~/a")
    }

    @Test func diagnosticsSettingsHoldNothingPrivate() {
        var s = AppSettings()
        s.proxy = "http://a:b@h:1"
        s.cookiesFile = "/Users/me/secret.txt"
        let clean = Diagnostics.sanitizedSettings(s)
        #expect(!clean.proxy.contains("a:b"))
        #expect(clean.cookiesFile == "(set)")
    }

    @Test func netscapeCookiesSurviveARoundTrip() {
        let cookies = [CookieRecord(domain: ".bilibili.com", path: "/", name: "SESSDATA", value: "a,b", secure: true, httpOnly: true, expires: 1900000000),
                       CookieRecord(domain: "www.youtube.com", path: "/x", name: "Y", value: "1", secure: false, httpOnly: false, expires: 0)]
        #expect(CookieVault.parseNetscape(CookieVault.toNetscape(cookies)) == cookies)
    }

    @Test func parserReportsTheExpectedFile() {
        #expect(YtDlpOutputParser().feed("VFN|/d/Me [id].mp4") == .expectedFile("/d/Me [id].mp4"))
    }

    @Test func aSpeedLimitMeansOneConnection() {
        var settings = AppSettings()
        settings.speedLimitKBps = 500
        let args = YtDlpArgs.download(request("https://www.youtube.com/watch?v=a"), settings: settings, env: .init(aria2Path: "/a/aria2c"))
        #expect(args.contains("-r") && args.contains("500K"))
        #expect(args[args.firstIndex(of: "-N")! + 1] == "1")
        #expect(!args.contains("--downloader"))
    }

    @Test func overwriteIsAskedOfYtDlpOnlyWhenWanted() {
        var r = request("https://www.youtube.com/watch?v=a")
        #expect(!YtDlpArgs.download(r, settings: AppSettings(), env: .init()).contains("--force-overwrites"))
        r.overwrite = true
        #expect(YtDlpArgs.download(r, settings: AppSettings(), env: .init()).contains("--force-overwrites"))
    }
}

/// Reaches the network; run with VIDFLOW_LIVE=1.
@Suite("Live", .enabled(if: ProcessInfo.processInfo.environment["VIDFLOW_LIVE"] == "1"), .serialized)
struct LiveTests {
    @Test func ffmpegFallsBackWhenTheUsualSourceIsDown() async throws {
        let saved = AppPaths.dataDir
        defer { AppPaths.dataDir = saved }
        AppPaths.dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("vf-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: AppPaths.dataDir) }
        let tools = ToolManager(ffmpegPrimary: "http://127.0.0.1:9/down")
        try await tools.install(.ffmpeg)
        let version = await tools.installedVersion(.ffmpeg)
        #expect(version?.isEmpty == false)
        #expect(!ToolManager.isUpToDate(.ffmpeg, installed: version, latest: "N-127654"))
        #expect(FileManager.default.isExecutableFile(atPath: AppPaths.binDir.appendingPathComponent("ffprobe").path))
    }
}
