import Foundation
import Testing
@testable import VidFlowCore

private let notImage = "[ext!=jpg][ext!=png][ext!=webp]"

extension VidFlowCoreTests {
    @Suite("YtDlpArgs")
    struct YtDlpArgsTests {
        init() { L.apply(language: "en") }

        @Test func videoPrefersAacAndAppliesHeightAndH264Sort() {
            let args = download(makeRequest(height: 1080), makeSettings { $0.preferH264 = true })
            #expect(args.contains("bv*\(notImage)+ba[acodec^=mp4a]/bv*\(notImage)+ba/b\(notImage)/b"))
            #expect(args.value(after: "-S") == "res:1080,hdr:SDR,vcodec:h264,acodec:m4a,fps,tbr")
            #expect(args.last == "https://www.youtube.com/watch?v=x")
        }

        @Test func autoPrefersBitrateOverCodecAtTheSameResolution() {
            // yt-dlp's default would rank AV1 first and pick the lowest-bitrate stream; we sort by bitrate instead.
            let args = download(makeRequest(height: 1080))
            #expect(args.value(after: "-S") == "res:1080,hdr:HDR10,fps,tbr")
            #expect(download(makeRequest()).value(after: "-S") == "res,hdr:HDR10,fps,tbr")
        }

        @Test func withoutFfmpegTakesSingleFileAndSkipsEmbedding() {
            let args = download(makeRequest(), AppSettings(), Env.noFfmpeg)
            #expect(args.value(after: "-f") == "b\(notImage)/b")
            #expect(!args.contains("--embed-thumbnail"))
            #expect(!args.contains("--ffmpeg-location"))
        }

        @Test func audioModeExtracts() {
            let args = download(makeRequest(mode: "mp3"))
            #expect(args.contains("-x"))
            #expect(args.value(after: "--audio-format") == "mp3")
        }

        @Test func chosenCodecIsTriedFirstWithFallback() {
            let h264 = download(makeRequest(height: 1080) { $0.codec = "h264" }, makeSettings { $0.preferH264 = false })
            let v = "[vcodec~='^(avc|h264)']"
            #expect(h264.value(after: "-f")
                == "bv*\(notImage)\(v)+ba[acodec^=mp4a]/bv*\(notImage)\(v)+ba/bv*\(notImage)+ba[acodec^=mp4a]/bv*\(notImage)+ba/b\(notImage)/b")

            // An explicit codec overrides the global compatibility mode's codec preference.
            let hevc = download(makeRequest { $0.codec = "h265" }, makeSettings { $0.preferH264 = true })
            #expect(hevc.value(after: "-S") == "res,hdr:HDR10,fps,tbr")

            let av1 = download(makeRequest { $0.codec = "av1" }, AppSettings(), Env.noFfmpeg)
            #expect(av1.value(after: "-f") == "b\(notImage)[vcodec~='^(av01|dav1)']/b\(notImage)/b")
        }

        @Test(arguments: [
            ("avc1.640032", "h264"), ("hev1.1.6.L120.90", "h265"), ("hvc1.2.4.L153", "h265"),
            ("av01.0.08M.08", "av1"), ("vp09.00.40.08", "vp9"), ("vp9", "vp9"),
        ])
        func mapsCodecFamilies(vcodec: String, expected: String) {
            #expect(VideoCodecs.family(vcodec) == expected)
        }

        @Test func noneIsNoCodecFamily() {
            #expect(VideoCodecs.family("none") == nil)
        }

        @Test func speedLimitIsPassed() {
            let args = download(makeRequest(), makeSettings { $0.speedLimitKBps = 2048 })
            #expect(args.value(after: "-r") == "2048K")
        }

        @Test func bilibiliSubtitlesIncludeDanmakuAndAreNotConverted() {
            let s = makeSettings { $0.saveDanmaku = true; $0.subtitleLanguages = "zh-Hans" }
            let args = download(makeRequest("https://www.bilibili.com/video/BV1", subs: true), s)
            #expect(args.value(after: "--sub-langs") == "zh-Hans,danmaku")
            #expect(!args.contains("--convert-subs"))

            let yt = download(makeRequest(subs: true), s)
            #expect(yt.value(after: "--sub-langs") == "zh-Hans")
            #expect(yt.contains("--convert-subs"))
        }

        @Test func emptySubtitleSettingFallsBackToChineseAndEnglish() {
            let args = download(makeRequest(subs: true), makeSettings { $0.subtitleLanguages = "" })
            #expect(args.value(after: "--sub-langs") == SubtitleLanguageSet.fallback)
        }

        @Test func cookiePriorityBrowserThenLogin() {
            let s = makeSettings { $0.cookiesBrowser = "edge" }
            var env = YtDlpArgs.Environment(loginCookieFile: "/tmp/login.txt")
            let args = YtDlpArgs.common(s, env)
            #expect(args.value(after: "--encoding") == "utf-8")
            #expect(args.value(after: "--cookies-from-browser") == "edge")

            env.skipBrowserCookies = true
            let fallback = YtDlpArgs.common(s, env)
            #expect(!fallback.contains("--cookies-from-browser"))
            #expect(fallback.value(after: "--cookies") == "/tmp/login.txt")

            // YouTube tries anonymously first: no cookies at all.
            env.skipLoginCookies = true
            #expect(!YtDlpArgs.common(s, env).contains("--cookies"))
        }

        @Test func infoUsesFlatPlaylistAndNoPlaylistForWatchLinks() {
            let args = YtDlpArgs.info(url: "https://www.youtube.com/watch?v=a&list=PL", settings: AppSettings(), env: Env.withFfmpeg)
            #expect(args.contains("--flat-playlist"))
            #expect(args.contains("--no-playlist"))
            #expect(!YtDlpArgs.info(url: "https://www.bilibili.com/video/BV1", settings: AppSettings(), env: Env.withFfmpeg).contains("--no-playlist"))
        }
    }

    @Suite("Format selection")
    struct FormatSelectionTests {
        init() { L.apply(language: "en") }

        @Test func webmRestrictsToVp9Av1AndOpusAndFallsBackToMkv() throws {
            let args = download(makeRequest("https://youtu.be/x") { $0.container = "webm" })
            let f = try #require(args.value(after: "-f"))
            #expect(f.hasPrefix("bv*\(notImage)[vcodec~='^(vp0?9|av01)']+ba[acodec~='^(opus|vorbis)']"))
            #expect(f.hasSuffix("/bv*\(notImage)+ba/b\(notImage)/b"))
            #expect(args.value(after: "--merge-output-format") == "webm/mkv")
        }

        @Test func mkvTakesAnyAudioAndRecodeIsOptIn() {
            let args = download(makeRequest("https://youtu.be/x") { $0.container = "mkv" })
            #expect(args.value(after: "-f") == "bv*\(notImage)+ba/b\(notImage)/b")
            #expect(args.value(after: "--merge-output-format") == "mkv")
            #expect(!args.contains("--recode-video"))

            let recode = download(makeRequest("https://youtu.be/x") { $0.container = "webm"; $0.codec = "h264"; $0.recode = true })
            #expect(recode.value(after: "--recode-video") == "webm")
        }

        @Test func audioTrackLanguageIsPreferredThenRelaxed() throws {
            let args = download(makeRequest("https://youtu.be/x") { $0.audioLanguage = "ja" })
            let chain = try #require(args.value(after: "-f")).split(separator: "/").map(String.init)
            #expect(chain[0] == "bv*\(notImage)+ba[acodec^=mp4a][language^=ja]")
            #expect(chain.contains("bv*\(notImage)+ba[language^=ja]"))
            #expect(chain.last == "b")
        }

        @Test func audioQualityLimitsAudioBitrateInVideoMode() {
            let args = download(makeRequest("https://youtu.be/x", height: 720) { $0.audioQuality = 128 })
            #expect(args.value(after: "-S") == "res:720,hdr:HDR10,fps,tbr,abr:128")
        }

        @Test(arguments: [
            ("mp3", 192, "192K", "ba/b"),
            ("m4a", 0, "0", "ba[acodec^=mp4a]/ba/b"), // by codec: Bilibili's FLAC is ".m4a" too
            ("opus", 160, "160K", "ba[acodec=opus]/ba/b"),
            ("flac", 320, "0", "ba/b"),                // lossless ignores a bitrate
            ("wav", 0, "0", "ba/b"),
        ])
        func audioOnlyFormats(format: String, quality: Int, expectedQuality: String, expectedFormat: String) {
            let args = download(makeRequest("https://youtu.be/x", mode: "audio") { $0.audioFormat = format; $0.audioQuality = quality })
            #expect(args.value(after: "--audio-format") == format)
            #expect(args.value(after: "--audio-quality") == expectedQuality)
            #expect(args.value(after: "-f") == expectedFormat)
        }

        @Test func legacyAudioModesStillWork() {
            let legacy = makeRequest("https://youtu.be/x", mode: "m4a")
            #expect(legacy.isAudio)
            #expect(download(legacy).value(after: "--audio-format") == "m4a")
        }

        @Test func jsRuntimeIsPassedWhenDenoIsInstalled() {
            var env = Env.withFfmpeg
            env.denoPath = "/usr/local/bin/deno"
            #expect(YtDlpArgs.common(AppSettings(), env).value(after: "--js-runtimes") == "deno:/usr/local/bin/deno")
            #expect(!YtDlpArgs.common(AppSettings(), Env.withFfmpeg).contains("--js-runtimes"))
            #expect(ToolManager.parseVersion(.deno, "deno 2.5.4 (stable, release, x86_64-pc-windows-msvc)") == "2.5.4")
        }

        @Test func formatSelectionNeverPicksAnImage() throws {
            let args = download(makeRequest("https://weibo.com/tv/show/1034:1", height: 320))
            let chain = try #require(args.value(after: "-f")).split(separator: "/").map(String.init)
            for s in chain.dropLast() { #expect(s.contains("[ext!=jpg]")) }
            #expect(args.value(after: "-S") == "res:320,hdr:HDR10,fps,tbr")
        }
    }

    @Suite("Media features")
    struct MediaFeatureTests {
        init() { L.apply(language: "en") }

        @Test(arguments: [
            (MediaFeatures.auto, false, "res,hdr:HDR10,fps,tbr"),   // HDR10 / HLG yes, Dolby Vision only on request
            (MediaFeatures.dolbyVision, false, "res,hdr,fps,tbr"),
            (MediaFeatures.sdr, false, "res,hdr:SDR,fps,tbr"),
            (MediaFeatures.auto, true, "res,hdr:SDR,vcodec:h264,acodec:m4a,fps,tbr"), // compatibility mode
        ])
        func pictureSteersTheSort(picture: String, compatibility: Bool, expected: String) {
            let req = makeRequest("https://www.bilibili.com/video/BV1") { $0.dynamicRange = picture }
            #expect(download(req, makeSettings { $0.preferH264 = compatibility }).value(after: "-S") == expected)
        }

        @Test func dolbyVisionAndHiResGoToMkvWithoutReencoding() {
            let dv = makeRequest("https://www.bilibili.com/video/BV1") { $0.recode = true; $0.dynamicRange = MediaFeatures.dolbyVision }
            let args = download(dv)
            #expect(args.value(after: "--merge-output-format") == "mkv")
            #expect(!args.contains("--recode-video"))

            let hiRes = download(makeRequest("https://www.bilibili.com/video/BV1") { $0.audioFormat = MediaFeatures.hiRes })
            #expect(hiRes.value(after: "--merge-output-format") == "mkv")
            #expect(hiRes.value(after: "-f")?.contains("+ba[acodec~='^(flac|alac)']") == true)

            let atmos = download(makeRequest("https://www.bilibili.com/video/BV1") { $0.audioFormat = MediaFeatures.atmos })
            #expect(atmos.value(after: "-f")?.contains("+ba[acodec~='^(ec-?3|eac3|ac-?4)']") == true)
        }

        @Test func mp4AutoAudioIsAacByCodecNotExtension() {
            // Bilibili labels its FLAC track ".m4a": an extension filter would let it into MP4.
            let args = download(makeRequest("https://www.bilibili.com/video/BV1"))
            #expect(args.value(after: "-f")?.hasPrefix("bv*\(notImage)+ba[acodec^=mp4a]") == true)
        }

        @Test func originalAudioKeepsTheSource() {
            let args = download(makeRequest("https://www.bilibili.com/video/BV1", mode: "audio") { $0.audioFormat = MediaFeatures.original })
            #expect(args.value(after: "--audio-format") == "best")
            #expect(args.value(after: "--audio-quality") == "0")
        }

        @Test func adviceFollowsWhatTheVideoOffers() throws {
            let info = try video(InfoParserTests.bilibili, "https://www.bilibili.com/video/BV18bnN6nEC6")

            let mp3 = makeTemplate { $0.mode = "audio"; $0.audioFormat = "mp3" }
            #expect(FormatCompatibility.check(mp3, video: info)?.suggestedAudioFormat == "flac")
            #expect(FormatCompatibility.check(mp3) == nil) // no Hi-Res known: nothing to say
            #expect(FormatCompatibility.check(makeTemplate { $0.mode = "audio"; $0.audioFormat = "flac" }, video: info) == nil)

            let dv = try #require(FormatCompatibility.check(makeTemplate { $0.dynamicRange = MediaFeatures.dolbyVision }, video: info))
            #expect(dv.info)
            #expect(dv.suggestedContainer == "mkv")
            #expect(FormatCompatibility.check(makeTemplate { $0.dynamicRange = MediaFeatures.dolbyVision; $0.container = "mkv" }, video: info) == nil)
        }

        @Test func labelsMentionTheChoices() {
            let t = makeTemplate { $0.dynamicRange = MediaFeatures.dolbyVision; $0.audioFormat = MediaFeatures.hiRes }
            let summary = DownloadLabels.summary(t)
            #expect(summary.contains(MediaFeatures.label("DV")))
            #expect(summary.contains(MediaFeatures.label(MediaFeatures.hiRes)))
            let label = DownloadLabels.label(t.toRequest(url: "https://www.bilibili.com/video/BV1", baseFolder: "o"), partIndex: nil)
            #expect(label.components(separatedBy: "·")[1].trimmingCharacters(in: .whitespaces).hasPrefix("MKV"))
        }
    }

    @Suite("Multi-connection downloads")
    struct MultiConnectionTests {
        init() { L.apply(language: "en") }

        static let req = makeRequest("https://www.youtube.com/watch?v=abc", height: 1080)
        static let aria2Env = YtDlpArgs.Environment(ffmpegDir: "/opt/ff", aria2Path: "/opt/bin/aria2c", systemProxy: "http://127.0.0.1:7897")

        @Test func aria2DownloadsWholeFilesAndYtDlpKeepsFragments() {
            let args = download(Self.req, AppSettings(), Self.aria2Env)
            #expect(args.value(after: "-N") == "8")
            #expect(args.contains("/opt/bin/aria2c"))
            #expect(args.contains("m3u8:native"))
            #expect(args.value(after: "--downloader-args")?.hasPrefix("aria2c:-x16") == true)
            // aria2c ignores the system's proxy setting, so it is passed on explicitly.
            #expect(args.value(after: "--proxy") == "http://127.0.0.1:7897")
        }

        @Test func ownProxyWinsAndNoAria2MeansNoDownloader() {
            let args = download(Self.req, makeSettings { $0.proxy = "socks5://10.0.0.1:1080" }, Self.aria2Env)
            let proxies = args.indices.filter { args[$0] == "--proxy" }.map { args[$0 + 1] }
            #expect(proxies == ["socks5://10.0.0.1:1080"])

            let plain = download(Self.req, AppSettings(), YtDlpArgs.Environment(ffmpegDir: "/opt/ff", systemProxy: "http://127.0.0.1:7897"))
            #expect(!plain.contains("--downloader"))
            #expect(!plain.contains("--proxy"))
            #expect(plain.contains("-N"))
        }

        @Test func youTubeAudioSkipsAria2() throws {
            let env = YtDlpArgs.Environment(ffmpegDir: "/opt/ff", aria2Path: "/opt/bin/aria2c")
            let args = download(Self.req, AppSettings(), env)
            #expect(args.value(after: "--extractor-args") == "youtube:formats=duplicate")
            #expect(args.contains("dash:native"))
            let chain = try #require(args.value(after: "-f")).split(separator: "/").map(String.init)
            // Each audio choice as a dash stream (yt-dlp downloads it), then as it is; the video side is untouched.
            #expect(chain[0] == chain[1] + "[protocol=http_dash_segments]")
            #expect(!chain[0].split(separator: "+")[0].contains("protocol"))
            #expect(chain.last == "b")

            let audio = download(makeRequest(Self.req.url, mode: "audio"), AppSettings(), env)
            let audioChain = try #require(audio.value(after: "-f")).split(separator: "/").map(String.init)
            let first = try #require(audioChain.first { !$0.contains("acodec") })
            #expect(first.hasPrefix("ba[protocol=http_dash_segments]"))
        }

        @Test func otherSitesAndNoAria2KeepOneFormatList() {
            let env = YtDlpArgs.Environment(ffmpegDir: "/opt/ff", aria2Path: "/opt/bin/aria2c")
            let x = download(makeRequest("https://x.com/a/status/1"), AppSettings(), env)
            #expect(!x.contains("--extractor-args"))
            #expect(x.value(after: "-f")?.contains("protocol") == false)
            let plain = download(Self.req, AppSettings(), Env.withFfmpeg)
            #expect(!plain.contains("--extractor-args"))
        }

        @Test func aria2VersionLine() {
            #expect(ToolManager.parseVersion(.aria2, "aria2 version 1.37.0") == "1.37.0")
        }
    }

    @Suite("Cover mode")
    struct CoverModeTests {
        init() { L.apply(language: "en") }

        @Test func coverDownloadsOnlyTheThumbnail() {
            let template = makeTemplate { $0.mode = "cover"; $0.maxHeight = 1080; $0.subtitles = true }
            let req = template.toRequest(url: "https://www.youtube.com/watch?v=abc", baseFolder: "o")
            #expect(req.isCover)
            #expect(!req.writeSubtitles)
            #expect(req.maxHeight == 0)
            #expect(!req.needsMkv)

            let args = download(req, AppSettings(), YtDlpArgs.Environment(ffmpegDir: "/opt/ff", aria2Path: "/opt/bin/aria2c"))
            #expect(args.contains("--skip-download"))
            #expect(args.contains("--write-thumbnail"))
            #expect(args.value(after: "--convert-thumbnails") == "jpg")
            #expect(!args.contains("-f"))
            #expect(!args.contains("--downloader"))
            // Nothing is downloaded, so the image's path is printed once the video is done.
            #expect(args.contains("after_video:VFF|%(thumbnails.-1.filepath)s"))

            // Without ffmpeg the image is kept as the site serves it.
            #expect(!download(req, AppSettings(), Env.noFfmpeg).contains("--convert-thumbnails"))
        }

        @Test func coverHasNoCompatibilityAdvice() {
            #expect(FormatCompatibility.check(makeTemplate { $0.mode = "cover"; $0.container = "webm"; $0.audioFormat = MediaFeatures.hiRes }) == nil)
        }
    }

    @Suite("Chapters and SponsorBlock")
    struct ChapterTests {
        init() { L.apply(language: "en") }

        func args(_ url: String, _ s: AppSettings, _ env: YtDlpArgs.Environment = Env.withFfmpeg) -> [String] {
            download(DownloadTemplate().toRequest(url: url, baseFolder: "o"), s, env)
        }

        @Test func chaptersAreEmbeddedByDefault() {
            let a = args("https://www.youtube.com/watch?v=abc", AppSettings())
            #expect(a.contains("--embed-chapters"))
            #expect(!a.contains { $0.hasPrefix("--sponsorblock") })
        }

        @Test func turningChaptersOffOverridesEmbedMetadata() {
            // --embed-metadata embeds chapters too unless told not to.
            let a = args("https://www.youtube.com/watch?v=abc", makeSettings { $0.embedChapters = false })
            #expect(a.contains("--embed-metadata"))
            #expect(a.contains("--no-embed-chapters"))
        }

        @Test func sponsorBlockMarkAddsChapters() {
            let a = args("https://youtu.be/abc", makeSettings { $0.embedChapters = false; $0.sponsorBlock = SponsorBlockModes.mark })
            #expect(a.value(after: "--sponsorblock-mark") == "all")
            #expect(a.contains("--embed-chapters"))
        }

        @Test func sponsorBlockRemoveCutsTheChosenCategories() {
            let a = args("https://www.youtube.com/watch?v=abc", makeSettings { $0.sponsorBlock = SponsorBlockModes.remove })
            #expect(a.value(after: "--sponsorblock-remove") == SponsorBlockModes.removedCategories)
        }

        @Test func sponsorBlockOnlyAppliesToYouTubeWithFfmpeg() {
            let s = makeSettings { $0.sponsorBlock = SponsorBlockModes.remove }
            #expect(!args("https://www.bilibili.com/video/BV1GJ411x7h7", s).contains("--sponsorblock-remove"))
            let plain = args("https://www.youtube.com/watch?v=abc", s, Env.noFfmpeg)
            #expect(!plain.contains("--sponsorblock-remove"))
            #expect(!plain.contains("--embed-chapters"))
        }

        @Test func coverModeHasNoChapters() {
            let req = makeTemplate { $0.mode = "cover" }.toRequest(url: "https://www.youtube.com/watch?v=abc", baseFolder: "o")
            let a = download(req, makeSettings { $0.sponsorBlock = SponsorBlockModes.mark })
            #expect(!a.contains("--embed-chapters"))
            #expect(!a.contains("--sponsorblock-mark"))
        }
    }
}
