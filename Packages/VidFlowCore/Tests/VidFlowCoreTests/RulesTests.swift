import Foundation
import Testing
@testable import VidFlowCore

extension VidFlowCoreTests {
    @Suite("NamingTemplate")
    struct NamingTemplateTests {
        init() { L.apply(language: "en") }

        @Test func translatesVariablesAndFolders() {
            let o = NamingTemplate.toOutputTemplate(fileTemplate: "{date} {title}", folderTemplate: "{platform}/{uploader}", platformName: "YouTube")
            #expect(o == "YouTube/%(uploader,channel,creator|Unknown)s/%(upload_date>%Y-%m-%d|unknown)s %(title).150B.%(ext)s")
        }

        @Test func defaultKeepsTheOldFileName() {
            #expect(NamingTemplate.toOutputTemplate(fileTemplate: NamingTemplate.defaultFileName, folderTemplate: "", platformName: "YouTube")
                == "%(title).150B [%(id)s].%(ext)s")
            #expect(NamingTemplate.toOutputTemplate(fileTemplate: "   ", folderTemplate: "", platformName: "YouTube")
                == "%(title).150B [%(id)s].%(ext)s")
        }

        @Test func cleansLiteralTextAndEscapesPercent() {
            // Slashes in a file name would create folders; forbidden characters and % are made safe.
            #expect(NamingTemplate.toOutputTemplate(fileTemplate: "a/b:c 100% {id}", folderTemplate: "", platformName: "YouTube")
                == "a_b_c 100%% %(id)s.%(ext)s")
            #expect(NamingTemplate.toOutputTemplate(fileTemplate: "{unknown}", folderTemplate: "", platformName: "YouTube") == "{unknown}.%(ext)s")
        }

        @Test func previewShowsAnExample() {
            // Mac: folders are separated by "/" (the Windows build shows "\").
            #expect(NamingTemplate.preview(fileTemplate: "{date} {title}", folderTemplate: "{platform}/{uploader}")
                == "YouTube/Blender/2014-11-10 Big Buck Bunny.mp4")
            #expect(NamingTemplate.preview(fileTemplate: NamingTemplate.defaultFileName, folderTemplate: "", ext: "mp3")
                == "Big Buck Bunny [aqz-KE-bpKQ].mp3")
        }

        @Test func presetsUseOnlyKnownVariables() {
            #expect(NamingTemplate.filePresets.contains(NamingTemplate.defaultFileName))
            for p in NamingTemplate.filePresets { #expect(NamingTemplate.unknownVariables(p).isEmpty, "\(p)") }
            for p in NamingTemplate.folderPresets { #expect(NamingTemplate.unknownVariables(p).isEmpty, "\(p)") }
        }

        @Test func unknownVariablesAreReported() {
            #expect(NamingTemplate.unknownVariables("{author} {title} {views} {author}") == ["author", "views"])
        }
    }

    @Suite("FormatCompatibility")
    struct CompatibilityTests {
        init() { TestEnv.prepare() }

        @Test func flagsIncompatibleCombinationsWithASuggestion() {
            let webmH264 = FormatCompatibility.check(makeTemplate { $0.container = "webm"; $0.codec = "h264" })
            #expect(webmH264?.suggestedContainer == "mkv")
            #expect(FormatCompatibility.check(makeTemplate { $0.container = "webm"; $0.audioFormat = "aac" })?.suggestedAudioFormat == "opus")
            #expect(FormatCompatibility.check(makeTemplate { $0.container = "mp4"; $0.audioFormat = "opus" })?.suggestedAudioFormat == "aac")
            #expect(FormatCompatibility.check(makeTemplate { $0.mode = "audio"; $0.audioFormat = "flac" }) != nil)
            #expect(FormatCompatibility.check(makeTemplate { $0.container = "mkv"; $0.codec = "h265"; $0.audioFormat = "opus" }) == nil)
            #expect(FormatCompatibility.check(DownloadTemplate()) == nil)
        }
    }

    @Suite("SubtitleLanguageSet")
    struct SubtitleLanguageTests {
        init() { TestEnv.prepare() }

        @Test func oldDefaultSettingReadsAsTicks() {
            let (chosen, other) = SubtitleLanguageSet.split("zh-Hans,zh-Hant,zh-CN,zh-TW,zh,ai-zh,en")
            #expect(chosen.sorted() == ["en", "zh-Hans", "zh-Hant"])
            #expect(other == "")
        }

        @Test func regionalCodesBelongToTheirLanguageAndUnknownCodesAreKept() {
            let (chosen, other) = SubtitleLanguageSet.split("en-US, ja , fr，de;zh-HK")
            #expect(chosen.sorted() == ["en", "ja", "zh-Hant"])
            #expect(other == "fr, de")
        }

        @Test func joinWritesEveryCodeOfTickedLanguagesWithoutDuplicates() {
            #expect(SubtitleLanguageSet.join(chosen: ["en", "zh-Hans"], other: "fr, en.*") == "zh-Hans,zh-CN,zh,ai-zh,en.*,fr")
            #expect(SubtitleLanguageSet.join(chosen: [], other: " ") == "")
            #expect(SubtitleLanguageSet.describe("zh,en,fr") == "简体中文, English, fr")
        }
    }

    @Suite("Format")
    struct FormatTests {
        init() { L.apply(language: "en") }

        @Test(arguments: [(512.0, "512 B"), (1536.0, "1.5 KB"), (Double(5 * 1024 * 1024), "5.0 MB")])
        func formatsBytes(bytes: Double, expected: String) {
            #expect(Format.bytes(bytes).replacingOccurrences(of: ",", with: ".") == expected)
        }

        @Test func formatsDurationAndDate() {
            #expect(Format.duration(212) == "3:32")
            #expect(Format.duration(3605) == "1:00:05")
            #expect(Format.date("20240131") == "2024-01-31")
            #expect(Format.date("2024") == nil)
        }

        @Test func heightAndQualityLabels() {
            #expect(Format.height(1080, fps: 60) == "1080p60 (Full HD)")
            #expect(Format.height(720) == "720p (HD)")
            #expect(Format.height(2160) == "2160p (4K)")
            #expect(Format.height(480) == "480p")
            #expect(Format.quality(QualityOption(height: 720, fps: 30, estimatedBytes: nil)) == "720p (HD)")
            #expect(Format.quality(QualityOption(height: 720, fps: 30, estimatedBytes: 5 * 1024 * 1024)) == "720p (HD)  ·  ~5.0 MB")
        }
    }

    @Suite("Download labels")
    struct DownloadLabelTests {
        @Test func downloadLabelsFollowCurrentLanguage() {
            let req = DownloadRequest(url: "https://www.bilibili.com/video/BV1", mode: "mp3", maxHeight: 0, writeSubtitles: false, outputFolder: "o")
            defer { L.apply(language: "en") }
            L.apply(language: "en")
            #expect(DownloadLabels.label(req, partIndex: 3) == "Bilibili  ·  MP3 audio  ·  P3")
            L.apply(language: "zh")
            #expect(DownloadLabels.label(req, partIndex: nil) == "哔哩哔哩  ·  MP3 音频")
            var done = DownloadRecord(request: req, title: "t")
            done.state = .completed
            done.filePath = "/Users/me/Downloads/x.mp3" // the Windows test used C:\a\x.mp3
            #expect(DownloadLabels.restingStatus(done) == "已完成 · x.mp3")
            var failed = DownloadRecord(request: req, title: "t")
            failed.state = .failed
            #expect(DownloadLabels.restingStatus(failed) == nil)
        }

        @Test func switchesLanguage() {
            defer { L.apply(language: "en") }
            L.apply(language: "en")
            #expect(L.get("Platform_Bilibili") == "Bilibili")
            L.apply(language: "zh")
            #expect(L.get("Platform_Bilibili") == "哔哩哔哩")
        }
    }

    @Suite("DownloadFilter")
    struct DownloadFilterTests {
        init() { TestEnv.prepare() }

        static func record(_ title: String, _ url: String, _ state: DownloadState) -> DownloadRecord {
            var r = DownloadRecord(request: DownloadRequest(url: url, mode: "video", maxHeight: 0, writeSubtitles: false, outputFolder: "o"), title: title)
            r.state = state
            return r
        }

        static let ytDone = record("Big Buck Bunny", "https://www.youtube.com/watch?v=aqz-KE-bpKQ", .completed)
        static let biliPaused = record("【官方 MV】Never Gonna Give You Up", "https://www.bilibili.com/video/BV1GJ411x7h7", .paused)
        static let xCanceled = record("A post", "https://x.com/user/status/1", .canceled)
        static let all = [ytDone, biliPaused, xCanceled]

        static func shown(_ f: DownloadFilter) -> [DownloadRecord] { all.filter(f.matches) }

        @Test func groupsByStatus() {
            #expect(Self.shown(DownloadFilter()) == Self.all)
            #expect(Self.shown(DownloadFilter(status: .active)) == [Self.biliPaused])
            #expect(Self.shown(DownloadFilter(status: .completed)) == [Self.ytDone])
            #expect(Self.shown(DownloadFilter(status: .failed)) == [Self.xCanceled])
        }

        @Test func filtersByPlatformAndText() {
            #expect(Self.shown(DownloadFilter(platform: .bilibili)) == [Self.biliPaused])
            #expect(Self.shown(DownloadFilter(query: "  bunny ")) == [Self.ytDone])
            #expect(Self.shown(DownloadFilter(query: "官方")) == [Self.biliPaused])
            #expect(Self.shown(DownloadFilter(query: "BV1GJ411")) == [Self.biliPaused])
            #expect(Self.shown(DownloadFilter(status: .completed, query: "never")).isEmpty)
            // The counts on the status choices follow the platform and text, not the status.
            #expect(DownloadFilter(status: .completed, platform: .bilibili).matchesExceptStatus(Self.biliPaused))
        }
    }
}
