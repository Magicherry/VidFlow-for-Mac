import Foundation
import Testing
@testable import VidFlowCore

extension VidFlowCoreTests {
    @Suite("YtDlpOutputParser")
    struct OutputParserTests {
        init() { TestEnv.prepare() }

        @Test func tracksVideoThenAudioStreams() throws {
            let p = YtDlpOutputParser()
            guard case .started(let parts, let title, let thumbnail)? = p.feed("VFS|137+140|900,100|https://i.ytimg.com/a.jpg|A | B title") else {
                throw TestError("expected a started event")
            }
            #expect(parts == 2)
            #expect(title == "A | B title")
            #expect(thumbnail == "https://i.ytimg.com/a.jpg")

            // Video is 900 of 1000 bytes in total: half of it is 45% of the whole download.
            let prog = try progress(p.feed("VFP|downloading|450|900|NA|2048|3|NA|NA"))
            #expect(near(prog.percent, 45))
            #expect(prog.part == 1)
            #expect(prog.total == 900)

            let videoDone = try progress(p.feed("VFP|finished|900|900|NA|NA|NA|NA|NA"))
            #expect(videoDone.streamFinished)
            #expect(!videoDone.processing)
            #expect(near(videoDone.percent, 90))

            // Audio continues from 90% instead of restarting at 0.
            let audio = try progress(p.feed("VFP|downloading|50|100|NA|NA|NA|NA|NA"))
            #expect(audio.part == 2)
            #expect(near(audio.percent, 95))

            let audioDone = try progress(p.feed("VFP|finished|100|100|NA|NA|NA|NA|NA"))
            #expect(audioDone.processing)
            #expect(audioDone.percent == 100)
        }

        @Test func fragmentedStreamUsesFragmentCountAndNeverGoesBackwards() throws {
            let p = YtDlpOutputParser()
            _ = p.feed("VFS|311|NA,NA|NA|T")
            // The running estimate grows faster than the bytes: bytes ÷ estimate would fall, fragments don't.
            let a = try progress(p.feed("VFP|downloading|5000|NA|10000|1|1|10|100"))
            let b = try progress(p.feed("VFP|downloading|5500|NA|20000|1|1|10|100"))
            #expect(near(a.percent, 10))
            #expect(near(b.percent, 10))
            let c = try progress(p.feed("VFP|downloading|9000|NA|20000|1|1|40|100"))
            #expect(near(c.percent, 40))
        }

        @Test func unknownVideoSizeIsEstimatedWhileAudioSizeIsKnown() throws {
            let p = YtDlpOutputParser()
            _ = p.feed("VFS|311+140|NA,1000|NA|T")
            // Video's estimate 9000 + audio 1000: video done = 90%.
            let half = try progress(p.feed("VFP|downloading|4500|NA|9000|1|1|50|100"))
            #expect(near(half.percent, 45))
            // A smaller later estimate would shift the weights down; the bar holds instead of going back.
            let later = try progress(p.feed("VFP|downloading|4600|NA|5000|1|1|50|100"))
            #expect(later.percent >= half.percent)
        }

        @Test func oldSevenFieldLinesStillParse() throws {
            let p = YtDlpOutputParser()
            #expect(near(try progress(p.feed("VFP|downloading|500|1000|NA|2048|3")).percent, 50))
        }

        @Test func usesEstimateWhenTotalUnknownAndIgnoresOtherLines() throws {
            let p = YtDlpOutputParser()
            let prog = try progress(p.feed("VFP|downloading|250|NA|1000.0|NA|NA"))
            #expect(near(prog.percent, 25))
            #expect(p.feed("[download] Destination: x.mp4") == nil)
            #expect(p.feed(#"VFF|C:\a\b.mp4"#) == .file(#"C:\a\b.mp4"#))
        }

        @Test func naThumbnailBecomesNull() {
            #expect(YtDlpOutputParser().feed("VFS|18|NA,NA|NA|Title") == .started(parts: 1, title: "Title", thumbnailURL: nil))
        }

        @Test func aria2ReadoutIsProgress() throws {
            let parser = YtDlpOutputParser()
            _ = parser.feed("VFS|137+140|100000000,10000000|NA|Title")
            let e = try progress(parser.feed("[#86c7bd 50MiB/100MiB(50%) CN:16 DL:20MiB ETA:2s]"))
            #expect(e.downloaded == Int64(50) << 20)
            #expect(e.total == Int64(100) << 20)
            #expect(e.speed == Double(20 << 20))
            #expect(e.eta == 2)
            #expect(e.part == 1)
            #expect(parser.feed(#"FILE: C:\x.f137.mp4"#) == nil)
        }

        @Test func finishedLineGluedAfterReadoutCounts() throws {
            let parser = YtDlpOutputParser()
            _ = parser.feed("VFS|137+140|100|NA|Title")
            let e = try progress(parser.feed("[#86c7bd 82MiB/83MiB(99%) CN:1 DL:33MiB]VFP|finished|100|100|NA|NA|NA|NA|NA"))
            #expect(e.streamFinished)
        }

        @Test(arguments: [("0B", Int64(0)), ("512KiB", Int64(512 * 1024)), ("1.5GiB", Int64(1610612736))])
        func aria2Sizes(text: String, bytes: Int64) {
            #expect(YtDlpOutputParser.bytes(text) == bytes)
        }

        @Test(arguments: [("45s", 45.0), ("3m12s", 192.0), ("1h2m", 3720.0)])
        func aria2Eta(text: String, seconds: Double) {
            #expect(YtDlpOutputParser.seconds(text) == seconds)
        }
    }

    @Suite("ErrorMapper")
    struct ErrorMapperTests {
        init() { L.apply(language: "en") }

        @Test func picksLastErrorLineAndAddsHint() {
            let raw = "WARNING: something\nERROR: first\nERROR: [youtube] x: Sign in to confirm you're not a bot\n"
            let msg = ErrorMapper.friendly(raw)
            #expect(msg.hasSuffix("Sign in to confirm you're not a bot"))
            #expect(msg.contains("\n")) // hint + raw line
            #expect(msg.hasPrefix(L.get("Error_BotCheck")))
        }

        @Test func joinsErrorSplitByCarriageReturn() {
            #expect(ErrorMapper.lastErrorLine("ERROR:\n[download] Got error: HTTP Error 503: Service Unavailable. Giving up after 10 retries\n")
                == "ERROR: [download] Got error: HTTP Error 503: Service Unavailable. Giving up after 10 retries")
        }

        @Test(arguments: [
            "ERROR: Could not copy Chrome cookie database. See https://github.com/yt-dlp/yt-dlp/issues/7271",
            "ERROR: Failed to decrypt with DPAPI",
        ])
        func detectsCookieReadErrors(line: String) {
            #expect(ErrorMapper.isCookieReadError(line))
        }

        @Test func noFormatsIsNotReportedAsUnavailable() {
            let raw = "ERROR: [youtube] qY6lCyN0CJA: Requested format is not available. Use --list-formats for a list of available formats"
            #expect(ErrorMapper.isNoFormats(raw))
            #expect(ErrorMapper.friendly(raw).hasPrefix(L.get("Error_NoFormats")))
            #expect(!ErrorMapper.friendly(raw).contains(L.get("Error_Unavailable")))
            #expect(ErrorMapper.friendly("ERROR: [youtube] x: Video unavailable").hasPrefix(L.get("Error_Unavailable")))
            #expect(ErrorMapper.friendly("ERROR: [youtube] zzzzzzzzzzz: This video is unavailable").hasPrefix(L.get("Error_Unavailable")))
        }

        @Test(arguments: [
            ("ERROR: [youtube] x: Sign in to confirm your age. This video may be inappropriate for some users.", true),
            ("ERROR: [youtube] x: Join this channel to get access to members-only content", true),
            ("ERROR: [youtube] x: Private video. Sign in if you've been granted access to this video", true),
            ("ERROR: [youtube] x: Requested format is not available", false),
            ("ERROR: [youtube] x: Video unavailable", false),
        ])
        func detectsSignInRequired(error: String, expected: Bool) {
            #expect(ErrorMapper.needsSignIn(error) == expected)
        }

        @Test func unknownErrorIsPassedThrough() {
            #expect(ErrorMapper.friendly("ERROR: weird") == "ERROR: weird")
        }
    }

    @Suite("InfoParser")
    struct InfoParserTests {
        init() { TestEnv.prepare() }

        static let videoJSON = #"""
        {
          "title": "Clip", "uploader": "Me", "duration": 100, "webpage_url": "https://www.youtube.com/watch?v=abc",
          "upload_date": "20240131",
          "thumbnails": [{"url": "https://i.ytimg.com/a.webp"}, {"url": "https://i.ytimg.com/hq.jpg"}],
          "formats": [
            {"format_id": "140", "vcodec": "none", "acodec": "mp4a", "filesize": 1000000},
            {"format_id": "137", "vcodec": "avc1", "acodec": "none", "height": 1080, "fps": 30, "filesize": 5000000},
            {"format_id": "299", "vcodec": "avc1", "acodec": "none", "height": 1080, "fps": 60, "filesize_approx": 8000000},
            {"format_id": "22", "vcodec": "avc1", "acodec": "mp4a", "height": 720, "fps": 30, "tbr": 800},
            {"format_id": "sb0", "vcodec": "none", "acodec": "none"}
          ]
        }
        """#

        @Test func parsesVideoWithQualitiesAndSizes() throws {
            let v = try video(Self.videoJSON, "https://youtu.be/abc")
            #expect(v.title == "Clip")
            #expect(v.platform == .youTube)
            #expect(v.thumbnailURL == "https://i.ytimg.com/hq.jpg")
            #expect(v.qualities.map(\.height) == [1080, 720])
            #expect(v.qualities[0].fps == 60)
            let largest1080PlusAudio: Int64 = 8_000_000 + 1_000_000 // largest 1080p stream + best audio
            let fromTbrTimesDuration: Int64 = 800 * 1000 / 8 * 100 + 1_000_000 // from tbr × duration
            #expect(v.qualities[0].estimatedBytes == largest1080PlusAudio)
            #expect(v.qualities[1].estimatedBytes == fromTbrTimesDuration)
            #expect(v.audioBytes == 1_000_000)
            #expect(v.codecs["h264"] == 1080) // all three avc1 streams; the highest is 1080p
            #expect(v.codecs.count == 1)
        }

        @Test func parsesPlaylistSkippingUnavailableEntries() throws {
            let json = #"""
            {"_type": "playlist", "title": "List", "webpage_url": "https://www.youtube.com/playlist?list=PL1",
             "entries": [
               {"id": "a", "url": "a", "title": "First", "duration": 10},
               null,
               {"url": "https://www.youtube.com/watch?v=b", "title": "Second",
                "thumbnails": [{"url": "https://i.ytimg.com/b.jpg"}]}
             ]}
            """#
            let p = try playlist(json, "https://www.youtube.com/playlist?list=PL1")
            #expect(p.entries.count == 2)
            #expect(p.entries[0].url == "https://www.youtube.com/watch?v=a")
            #expect(p.entries[1].index == 2)
            #expect(p.thumbnailURL == "https://i.ytimg.com/b.jpg")
        }

        @Test func upgradesHttpThumbnails() throws {
            let v = try video(#"{"title":"t","thumbnail":"http://i0.hdslb.com/x.jpg","webpage_url":"https://www.bilibili.com/video/BV1"}"#,
                              "https://www.bilibili.com/video/BV1")
            #expect(v.thumbnailURL == "https://i0.hdslb.com/x.jpg")
            #expect(v.platform == .bilibili)
        }

        @Test func listsAudioTracksOriginalFirstOnlyWhenThereIsAChoice() throws {
            let multi = #"""
            {"title":"t","webpage_url":"https://www.youtube.com/watch?v=x","formats":[
              {"format_id":"a1","vcodec":"none","acodec":"opus","language":"es","language_preference":-1},
              {"format_id":"a2","vcodec":"none","acodec":"opus","language":"en","language_preference":10},
              {"format_id":"a3","vcodec":"none","acodec":"mp4a","language":"ja","language_preference":-1},
              {"format_id":"v","vcodec":"avc1","acodec":"none","height":720,"language":"en"}]}
            """#
            #expect(try video(multi, "https://youtu.be/x").audioLanguages == ["en", "es", "ja"])

            let single = #"{"title":"t","formats":[{"vcodec":"none","acodec":"opus","language":"en"}]}"#
            #expect(try video(single, "https://youtu.be/x").audioLanguages.isEmpty)
        }

        @Test func previewImagesAreNotQualitiesAndPortraitUsesTheShortSide() throws {
            // Weibo lists a 180x320 JPEG "scrubber" among its formats; its videos are portrait.
            let json = #"""
            {"_type":"video","id":"5356127206245063","title":"t","webpage_url":"https://weibo.com/tv/show/1034:1","duration":132,
             "formats":[
               {"format_id":"scrubber_hd","ext":"jpg","width":180,"height":320,"vcodec":"unknown","acodec":"unknown"},
               {"format_id":"mp4_hd","ext":"mp4","width":540,"height":820,"vcodec":"avc1.64001f","acodec":"mp4a.40.5","filesize":16230000},
               {"format_id":"mp4_1080p","ext":"mp4","width":1080,"height":1644,"vcodec":"avc1.640032","acodec":"mp4a.40.5","filesize":43350000}]}
            """#
            let info = try video(json, "https://weibo.com/tv/show/1034:1")
            #expect(info.qualities.map(\.height) == [1080, 540])
            #expect(info.codecs["h264"] == 1080)
        }

        /// Trimmed from yt-dlp's answer for a Bilibili video with Dolby Vision, Dolby Atmos and Hi-Res.
        static let bilibili = #"""
        {"_type":"video","id":"BV18bnN6nEC6","title":"t","webpage_url":"https://www.bilibili.com/video/BV18bnN6nEC6","duration":200,
         "formats":[
           {"format_id":"30250","ext":"m4a","vcodec":"none","acodec":"ec-3","tbr":1665},
           {"format_id":"30280","ext":"m4a","vcodec":"none","acodec":"mp4a.40.2","tbr":320},
           {"format_id":"30251","ext":"m4a","vcodec":"none","acodec":"flac","tbr":1690},
           {"format_id":"30120","ext":"mp4","width":3840,"height":2160,"vcodec":"avc1.640034","acodec":"none","dynamic_range":"SDR","tbr":21240},
           {"format_id":"30126","ext":"mp4","width":3840,"height":2160,"vcodec":"hvc1.2.4.L156.90","acodec":"none","dynamic_range":"DV","tbr":21003}]}
        """#

        @Test func featuresAreDetected() throws {
            let info = try video(Self.bilibili, "https://www.bilibili.com/video/BV18bnN6nEC6")
            #expect(info.hdrKinds == ["DV"])
            #expect(info.hasDolbyVision)
            #expect(!info.hasHdr)
            #expect(info.hasHiRes)
            #expect(info.hasAtmos)
            #expect(info.features == ["DV", MediaFeatures.hiRes, MediaFeatures.atmos])
        }
    }

    @Suite("BilibiliApi")
    struct BilibiliApiTests {
        init() { TestEnv.prepare() }

        @Test func fillsPartNamesCoverAndUploader() {
            var list = PlaylistInfo(url: "https://www.bilibili.com/video/BV1Rx411876f", title: "Course")
            list.platform = .bilibili
            list.entries = [
                PlaylistEntry(index: 1, url: "https://www.bilibili.com/video/BV1Rx411876f?p=1", title: "Video 1"),
                PlaylistEntry(index: 2, url: "https://www.bilibili.com/video/BV1Rx411876f?p=2", title: "Video 2"),
            ]
            let view = #"""
            {"code":0,"data":{"pic":"http://i0.hdslb.com/c.jpg","owner":{"name":"Up"},
             "pages":[{"page":1,"part":"Intro","duration":61},{"page":2,"part":"","duration":5}]}}
            """#
            let result = BilibiliApi.applyView(list, json: view)
            #expect(result.entries[0].title == "P1 Intro")
            #expect(result.entries[0].duration == 61)
            #expect(result.entries[1].title == "Video 2") // empty part name keeps the fallback
            #expect(result.thumbnailURL == "https://i0.hdslb.com/c.jpg")
            #expect(result.uploader == "Up")
        }

        @Test func errorResponseLeavesPlaylistUnchanged() {
            let list = PlaylistInfo(url: "u", title: "t")
            #expect(BilibiliApi.applyView(list, json: #"{"code":-404,"data":null}"#) == list)
        }
    }
}
