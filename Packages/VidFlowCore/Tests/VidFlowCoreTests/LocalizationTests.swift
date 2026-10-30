import Foundation
import Testing
@testable import VidFlowCore

private let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let sourcesDir = packageRoot.appendingPathComponent("Sources/VidFlowCore")

extension VidFlowCoreTests {
    @Suite("Localization")
    struct LocalizationTests {
        init() { L.apply(language: "en") }

        /// Strings.tsv / Strings.mac.tsv: key, English, Chinese.
        static func rows(_ file: String) throws -> [(key: String, en: String, zh: String)] {
            let text = try String(contentsOf: sourcesDir.appendingPathComponent("Resources/\(file)"), encoding: .utf8)
            return text.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                return f.count >= 3 ? (f[0], f[1], f[2]) : nil
            }
        }

        @Test(arguments: ["Strings.tsv", "Strings.mac.tsv"])
        func chineseAndEnglishAreBothFilledIn(file: String) throws {
            let rows = try Self.rows(file)
            #expect(!rows.isEmpty)
            for r in rows {
                #expect(!r.en.isEmpty, "\(r.key) has no English text")
                #expect(!r.zh.isEmpty, "\(r.key) has no Chinese text")
                let placeholders = { (s: String) in (0..<6).filter { s.contains("{\($0)}") } }
                #expect(placeholders(r.en) == placeholders(r.zh), "\(r.key): placeholders differ between languages")
            }
            #expect(Set(rows.map(\.key)).count == rows.count, "duplicate keys in \(file)")
        }

        @Test func everyTableKeyIsLoaded() throws {
            for r in try Self.rows("Strings.tsv") + Self.rows("Strings.mac.tsv") { #expect(L.has(r.key), "\(r.key)") }
        }

        @Test func everyKeyUsedInTheTestsExists() {
            let keys = [
                "Error_NoFormats", "Error_Unavailable", "Error_BotCheck", "Error_UnexpectedExit", "Error_DouyinUnavailable",
                "Error_DouyinNotVideo", "Platform_Bilibili", "Platform_Douyin", "Platform_Weibo", "Platform_Xiaohongshu",
                "Platform_Other", "Label_Audio", "Label_AudioOriginal", "Status_Completed", "Status_CompletedFile",
                "Feature_DolbyVision", "Feature_HiRes", "Feature_Atmos", "Quality_FullHD", "Quality_HD", "Quality_Best",
                "Size_Approx", "Mode_Cover", "Options_Subtitles", "Untitled", "Playlist_EntryFallback", "Update_ChecksumMismatch",
                "Compat_WebmVideo", "Compat_WebmAudio", "Compat_Mp4Opus", "Compat_LosslessFromLossy", "Compat_SavedAsMkv",
                "Compat_HdrMkv", "Compat_HiResAvailable", "Preset_Best", "Preset_HD", "Preset_Compatible", "Preset_SaveSpace",
                "Preset_AudioOnly",
            ]
            for k in keys { #expect(L.has(k), "missing \(k)") }
            #expect(!L.has("No_Such_Key"))
            #expect(L.get("No_Such_Key") == "No_Such_Key")
        }

        @Test func everyKeyUsedInSourceExists() throws {
            let call = try NSRegularExpression(pattern: #"L\.(?:get|format)\(\s*"([A-Za-z0-9_]+)""#)
            // Keys that reach L.get through a variable: nameKey / messageKey / purposeKey / missingKey values.
            let literal = try NSRegularExpression(pattern: #""([A-Z][A-Za-z0-9]*_[A-Za-z0-9_]+)""#)
            // Capitalised words with an underscore that are not strings: a cookie name and an environment variable.
            let notKeys: Set<String> = ["DedeUserID__ckMd5", "LOGIN_INFO", "VIDFLOW_UPDATE_MANIFEST"]
            var used = Set<String>()
            let files = try FileManager.default.contentsOfDirectory(at: sourcesDir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
            #expect(!files.isEmpty)
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                let range = NSRange(text.startIndex..., in: text)
                for re in [call, literal] {
                    for m in re.matches(in: text, range: range) {
                        if let r = Range(m.range(at: 1), in: text) { used.insert(String(text[r])) }
                    }
                }
            }
            used.subtract(notKeys)
            #expect(used.count > 50)
            #expect(used.filter { !L.has($0) }.sorted().isEmpty, "keys with no entry: \(used.filter { !L.has($0) }.sorted())")
        }

        @Test func everyToolHasItsStrings() {
            for tool in Tool.allCases {
                #expect(L.has(tool.purposeKey), "\(tool.purposeKey)")
                #expect(L.has(tool.missingKey), "\(tool.missingKey)")
            }
        }

        @Test func platformNamesFollowTheLanguage() {
            defer { L.apply(language: "en") }
            L.apply(language: "en")
            #expect(Platform.bilibili.displayName == "Bilibili")
            #expect(Platform.youTube.displayName == "YouTube")
            L.apply(language: "zh")
            #expect(Platform.bilibili.displayName == "哔哩哔哩")
            #expect(Platform.youTube.displayName == "YouTube")
            #expect(L.isChinese)
        }

        @Test func formatFillsPlaceholders() {
            #expect(L.format("Label_Audio", "MP3") == "MP3 audio")
        }
    }
}
