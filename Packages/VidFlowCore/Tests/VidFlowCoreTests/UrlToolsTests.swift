import Foundation
import Testing
@testable import VidFlowCore

extension VidFlowCoreTests {
    @Suite("UrlTools")
    struct UrlToolsTests {
        init() { TestEnv.prepare() }

        @Test func extractsUrlFromBilibiliShareText() {
            let text = "【【官方 MV】Never Gonna Give You Up-哔哩哔哩】 https://b23.tv/AbCd123"
            #expect(UrlTools.extractURL(text) == "https://b23.tv/AbCd123")
        }

        @Test func extractsAllDistinctUrlsForBatchPaste() {
            let text = "https://youtu.be/a\nhttps://www.bilibili.com/video/BV1x, https://youtu.be/a"
            #expect(UrlTools.extractURLs(text) == ["https://youtu.be/a", "https://www.bilibili.com/video/BV1x"])
        }

        @Test(arguments: [
            ("https://www.youtube.com/watch?v=x", Platform.youTube),
            ("https://youtu.be/x", Platform.youTube),
            ("https://b23.tv/x", Platform.bilibili),
            ("https://www.bilibili.com/video/BV1x", Platform.bilibili),
            ("https://example.com/v", Platform.other),
        ])
        func detectsPlatform(url: String, expected: Platform) {
            #expect(UrlTools.detectPlatform(url) == expected)
        }

        @Test func watchLinkWithPlaylistIsTreatedAsVideo() {
            #expect(UrlTools.isYouTubeVideoInPlaylist("https://www.youtube.com/watch?v=abc&list=PL1"))
            #expect(!UrlTools.isYouTubeVideoInPlaylist("https://www.youtube.com/playlist?list=PL1"))
        }

        // Mac only: UrlTools.safeFolderName names the folder of a downloaded playlist.
        @Test func safeFolderNameReplacesForbiddenCharacters() {
            #expect(UrlTools.safeFolderName("a/b:c\\d<e>f\"g|h?i*j") == "a_b_c_d_e_f_g_h_i_j")
            #expect(UrlTools.safeFolderName("a\u{1}b\tc") == "a_b_c")
            #expect(UrlTools.safeFolderName("///") == "___")
        }

        @Test func safeFolderNameTrimsSpacesAndDots() {
            #expect(UrlTools.safeFolderName("  My list  ") == "My list")
            #expect(UrlTools.safeFolderName("name...") == "name")
            // A leading dot would hide the folder in Finder.
            #expect(UrlTools.safeFolderName(".hidden") == "hidden")
            #expect(UrlTools.safeFolderName("..a.b..") == "a.b")
        }

        @Test func safeFolderNameFallsBackToPlaylist() {
            #expect(UrlTools.safeFolderName("") == "Playlist")
            #expect(UrlTools.safeFolderName("   ") == "Playlist")
            #expect(UrlTools.safeFolderName("...") == "Playlist")
        }

        @Test func safeFolderNameIsCappedAt80CharactersAndKeepsUnicode() {
            let long = String(repeating: "合", count: 100)
            #expect(UrlTools.safeFolderName(long) == String(repeating: "合", count: 80))
            #expect(UrlTools.safeFolderName("合集 日本語 – ünï") == "合集 日本語 – ünï")
        }
    }

    @Suite("Douyin links")
    struct DouyinLinkTests {
        init() { TestEnv.prepare() }

        @Test(arguments: [
            ("https://www.douyin.com/video/7412345678901234567", "https://www.douyin.com/video/7412345678901234567"),
            ("https://www.douyin.com/jingxuan?modal_id=7412345678901234567", "https://www.douyin.com/video/7412345678901234567"),
            ("https://www.douyin.com/user/MS4wLjAB?from_tab_name=main&modal_id=7412345678901234567", "https://www.douyin.com/video/7412345678901234567"),
            ("https://www.iesdouyin.com/share/video/7412345678901234567/?region=CN", "https://www.douyin.com/video/7412345678901234567"),
        ])
        func linksBecomeVideoLinks(url: String, expected: String) {
            #expect(UrlTools.canonicalDouyinURL(url) == expected)
        }

        @Test func shareTextYieldsTheShortLinkAndIsRecognised() throws {
            let share = "7.94 复制打开抖音，看看【某某的作品】今天的晚霞 # 风景 https://v.douyin.com/iABCdEf/ 12/31 Abc:/"
            let url = try #require(UrlTools.extractURL(share))
            #expect(url == "https://v.douyin.com/iABCdEf/")
            #expect(UrlTools.detectPlatform(url) == .douyin)
            #expect(UrlTools.isShortLink(url))
            #expect(UrlTools.canonicalDouyinURL(url) == nil) // resolved over the network by ShortLinks
        }

        @Test func profilePagesAreNotVideos() {
            #expect(UrlTools.canonicalDouyinURL("https://www.douyin.com/user/MS4wLjAB") == nil)
        }

        /// Shape of Douyin's web aweme/detail answer (trimmed to the fields VidFlow reads).
        static let detail = #"""
        {"status_code":0,"aweme_detail":{
          "aweme_id":"7412345678901234567","desc":"晚霞 #风景\n第二行","create_time":1730000000,
          "author":{"nickname":"某某"},
          "images":null,
          "video":{"duration":15200,
            "cover":{"url_list":["https://p3.douyinpic.com/cover.jpeg"]},
            "play_addr":{"url_list":["https://www.douyin.com/aweme/v1/play/?video_id=v0"],"width":720,"height":1280},
            "bit_rate":[
              {"bit_rate":1200000,"is_h265":0,"play_addr":{"url_list":["https://www.douyin.com/aweme/v1/play/?x=1","https://v26-web.douyinvod.com/720.mp4"],"width":720,"height":1280,"data_size":2000000}},
              {"bit_rate":2600000,"is_h265":1,"play_addr":{"url_list":["https://v26-web.douyinvod.com/1080-h265.mp4"],"width":1080,"height":1920,"data_size":5000000}},
              {"bit_rate":3100000,"is_h265":0,"play_addr":{"url_list":["https://v26-web.douyinvod.com/1080-h264.mp4"],"width":1080,"height":1920,"data_size":6000000}}
            ]}}}
        """#

        @Test func detailBecomesVideoInfo() throws {
            let video = try DouyinParser.parse(Self.detail)
            #expect(video.id == "7412345678901234567")
            #expect(video.author == "某某")
            #expect(video.duration == 15.2)
            // CDN over redirect
            #expect(try #require(video.streams.first { $0.resolution == 720 }).url == "https://v26-web.douyinvod.com/720.mp4")

            let info = DouyinParser.toVideoInfo(video)
            #expect(info.url == "https://www.douyin.com/video/7412345678901234567")
            #expect(info.platform == .douyin)
            #expect(info.qualities.map(\.height) == [1080, 720]) // portrait: the short side
            #expect(info.qualities[0].estimatedBytes == 6000000)
            #expect(info.codecs["h265"] == 1080)
        }

        @Test(arguments: [
            (0, "auto", "1080-h264.mp4"),   // best: highest resolution, then bitrate
            (0, "h265", "1080-h265.mp4"),
            (720, "auto", "720.mp4"),
            (480, "auto", "720.mp4"),       // nothing that small: the smallest there is
            (720, "h265", "720.mp4"),       // codec not offered at that size: fall back
        ])
        func picksTheStreamThatFits(maxHeight: Int, codec: String, expected: String) throws {
            #expect(DouyinParser.pick(try DouyinParser.parse(Self.detail), maxHeight: maxHeight, codec: codec).url.hasSuffix(expected))
        }

        @Test func photoPostsAndMissingVideosAreRefused() {
            #expect(throws: YtDlpError.self) { try DouyinParser.parse(#"{"status_code":0,"aweme_detail":null}"#) }
            #expect(throws: YtDlpError.self) {
                try DouyinParser.parse(#"{"aweme_detail":{"aweme_id":"1","desc":"","images":[{"url_list":["a"]}],"video":{}}}"#)
            }
        }

        @Test func knownValuesNameTheFile() {
            let known: [String: String?] = ["title": "晚霞 #风景\n第二行", "uploader": "某某", "id": "7412"]
            let output = NamingTemplate.toOutputTemplate(fileTemplate: "{uploader} - {title} [{id}]", folderTemplate: "{platform}",
                                                         platformName: "抖音", known: known)
            #expect(output == "抖音/某某 - 晚霞 #风景 第二行 [7412].%(ext)s")
        }
    }

    @Suite("Platform links")
    struct PlatformLinkTests {
        init() { TestEnv.prepare() }

        @Test(arguments: [
            ("https://weibo.com/tv/show/1034:5356122991951924", Platform.weibo),
            ("https://m.weibo.cn/status/5123456789012345", Platform.weibo),
            ("http://t.cn/AXlFHACG", Platform.weibo),
            ("https://www.xiaohongshu.com/explore/6411cf99000000001300b6d9?xsec_token=AB", Platform.xiaohongshu),
            ("http://xhslink.com/a/AbCdEf", Platform.xiaohongshu),
            ("https://x.com/NASA/status/2113776971603689874", Platform.x),
            ("https://twitter.com/NASA/status/2113776971603689874", Platform.x),
            ("https://mobile.twitter.com/NASA/status/2113776971603689874", Platform.x),
            ("https://t.co/abc123", Platform.x),
            ("https://www.iesdouyin.com/share/video/7412345678901234567/", Platform.douyin),
            ("https://www.netflix.com/title/1", Platform.other),   // not "x.com"
            ("https://notweibo.com.example.org/", Platform.other),
            ("not a link", Platform.other),
        ])
        func platformComesFromTheHost(url: String, expected: Platform) {
            #expect(UrlTools.detectPlatform(url) == expected)
        }

        @Test(arguments: [
            ("https://video.weibo.com/show?fid=1034:5356122991951924", "https://weibo.com/tv/show/1034:5356122991951924"),
            ("https://weibo.com/tv/show/1034:5356122991951924?from=old_pc_videoshow", "https://weibo.com/tv/show/1034:5356122991951924"),
            ("https://video.weibo.com/show?fid=1034%3A5356122991951924", "https://weibo.com/tv/show/1034:5356122991951924"),
        ])
        func weiboVideoLinksBecomeTvLinks(url: String, expected: String) {
            #expect(UrlTools.canonicalWeiboURL(url) == expected)
        }

        @Test func weiboPostLinksAreLeftForYtDlp() {
            #expect(UrlTools.canonical("https://m.weibo.cn/status/5123456789012345") == nil)
        }

        @Test(arguments: [
            ("http://t.cn/AXlFHACG", true),
            ("http://xhslink.com/a/AbCdEf", true),
            ("https://v.douyin.com/iABCdEf/", true),
            ("https://t.co/abc123", false),          // yt-dlp follows these itself
            ("https://weibo.com/tv/show/1034:1", false),
        ])
        func shortLinksAreRecognised(url: String, expected: Bool) {
            #expect(UrlTools.isShortLink(url) == expected)
        }

        @Test func onlySomePlatformsHaveSignIn() {
            #expect(CookieVault.signInPlatforms.contains(.bilibili))
            #expect(!CookieVault.signInPlatforms.contains(.weibo))
            #expect(!CookieVault(secret: MemorySecret()).isLoggedIn(.x))
        }
    }
}
