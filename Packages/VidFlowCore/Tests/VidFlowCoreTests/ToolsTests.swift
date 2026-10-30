import CryptoKit
import Foundation
import Testing
@testable import VidFlowCore

extension VidFlowCoreTests {
    @Suite("ToolManager versions")
    struct ToolVersionTests {
        init() { TestEnv.prepare() }

        @Test(arguments: [
            ("2026.10.21", "2026.10.21", true),
            ("2026.10.21", "2026.11.02", false),
            ("2026.11.02.233154", "2026.11.02", true), // nightly is newer than the release it follows
            (Optional<String>.none, "2026.10.21", false),
            ("2026.10.21", Optional<String>.none, false),
        ] as [(String?, String?, Bool)])
        func comparesYtDlpVersions(installed: String?, latest: String?, expected: Bool) {
            #expect(ToolManager.isUpToDate(.ytDlp, installed: installed, latest: latest) == expected)
        }

        @Test func yearMonthDayOrderingIsNumericNotTextual() {
            #expect(ToolManager.isUpToDate(.ytDlp, installed: "2026.10.9", latest: "2026.10.10") == false)
            #expect(ToolManager.isUpToDate(.ytDlp, installed: "2026.10.10", latest: "2026.10.9") == true)
        }

        @Test func surroundingWhitespaceIsIgnored() {
            #expect(ToolManager.isUpToDate(.ytDlp, installed: " 2026.10.21 ", latest: "2026.10.21"))
            #expect(ToolManager.isUpToDate(.ytDlp, installed: " 2026.10.21\n", latest: "2026.10.21"))
        }

        // Mac: ffmpeg snapshots count up as N-127654 (the Windows build compares build dates).
        @Test func comparesFfmpegBuildNumbers() {
            #expect(ToolManager.ffmpegBuild(fromPath: "/download/macos/arm64/1792426763_N-127654-g7045cc9b80/ffmpeg.zip") == "N-127654")
            #expect(ToolManager.ffmpegBuild(fromPath: "/download/macos/arm64/7.1/ffmpeg.zip") == nil)

            let installed = "N-128018-ga881f0a9ad"
            #expect(ToolManager.isUpToDate(.ffmpeg, installed: installed, latest: "N-128018"))
            #expect(ToolManager.isUpToDate(.ffmpeg, installed: installed, latest: "N-127654"))
            #expect(!ToolManager.isUpToDate(.ffmpeg, installed: installed, latest: "N-128019"))
            #expect(!ToolManager.isUpToDate(.ffmpeg, installed: "7.1-full_build", latest: "N-128018")) // no build number: can't tell
            #expect(!ToolManager.isUpToDate(.ffmpeg, installed: installed, latest: nil))
        }

        @Test func readsTagFromReleaseRedirect() {
            #expect(ToolManager.tag(from: URL(string: "https://github.com/yt-dlp/yt-dlp/releases/tag/2026.10.21")) == "2026.10.21")
            #expect(ToolManager.tag(from: URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest")) == nil)
            #expect(ToolManager.tag(from: nil) == nil)
        }

        // ---- Mac only ----

        @Test(arguments: [
            (Tool.ffmpeg, "ffmpeg version N-12345-gabcdef Copyright (c) 2000-2026 the FFmpeg developers", "N-12345-gabcdef"),
            (Tool.ffmpeg, "ffmpeg version 7.1 Copyright (c) 2000-2025", "7.1"),
            (Tool.deno, "deno 2.5.4 (stable, release, aarch64-apple-darwin)", "2.5.4"),
            (Tool.aria2, "aria2 version 1.37.0", "1.37.0"),
            (Tool.ytDlp, "2026.10.21", "2026.10.21"),
            (Tool.deno, "something else", "something else"),
            (Tool.aria2, "aria2c 1.0", "aria2c 1.0"),
        ])
        func parsesVersionLines(tool: Tool, line: String, expected: String) {
            #expect(ToolManager.parseVersion(tool, line) == expected)
        }
    }

    @Suite("ToolManager checksums")
    struct ChecksumTests {
        static let a = String(repeating: "a", count: 64)
        static let b = String(repeating: "b", count: 64)

        @Test func bareHashFile() {
            #expect(ToolManager.checksum(in: Self.a + "\n", for: "anything.zip") == Self.a)
            #expect(ToolManager.checksum(in: Self.a.uppercased(), for: "x") == Self.a)
        }

        @Test func picksTheLineOfTheNamedFile() {
            let text = "\(Self.a)  yt-dlp\n\(Self.b)  yt-dlp_macos\n"
            #expect(ToolManager.checksum(in: text, for: "yt-dlp_macos") == Self.b)
            #expect(ToolManager.checksum(in: text, for: "yt-dlp") == Self.a)
        }

        @Test func binaryModeMarkerAndWindowsLineEndings() {
            #expect(ToolManager.checksum(in: "\(Self.a) *ffmpeg.zip\r\n\(Self.b) *ffprobe.zip\r\n", for: "ffprobe.zip") == Self.b)
        }

        @Test func uppercaseHashesAreLowercased() {
            #expect(ToolManager.checksum(in: "\(Self.a.uppercased())  x.zip\n\(Self.b)  y.zip", for: "x.zip") == Self.a)
        }

        @Test func noMatchGivesNil() {
            #expect(ToolManager.checksum(in: "\(Self.a)  x.zip\n\(Self.b)  y.zip\n", for: "z.zip") == nil)
            #expect(ToolManager.checksum(in: "not-a-hash  z.zip", for: "z.zip") == nil)
            #expect(ToolManager.checksum(in: "", for: "z.zip") == nil)
            #expect(ToolManager.checksum(in: "too short\n", for: "z.zip") == nil)
        }
    }

    @Suite("UpdateService")
    struct UpdateServiceTests {
        init() { TestEnv.prepare() }

        static func hex(_ bytes: [UInt8]) -> String {
            SHA256.hash(data: Data(bytes)).map { String(format: "%02X", $0) }.joined()
        }

        @Test func macManifestHasItsOwnName() {
            if ProcessInfo.processInfo.environment["VIDFLOW_UPDATE_MANIFEST"]?.isEmpty ?? true {
                #expect(UpdateService.manifestSource.hasSuffix("/update-macos.json"))
            }
        }

        @Test func parsesTheManifest() throws {
            let json = #"{"version":"1.2.3","url":"https://example.com/v.zip","sha256":"abc","size":10,"notes":"n","published":"2026-10-25T00:00:00Z"}"#
            let m = try UpdateService.parseManifest(Data(json.utf8))
            #expect(m.version == "1.2.3")
            #expect(m.size == 10)
            #expect(m.published != nil)
        }

        @Test func verifiesSizeAndChecksum() throws {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("vf-verify-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: file) }
            try Data([1, 2, 3, 4]).write(to: file)
            let good = UpdateManifest(version: "9.9.9", url: "u", sha256: Self.hex([1, 2, 3, 4]), size: 4)
            #expect(UpdateService.verify(file, good))
            var wrongSize = good
            wrongSize.size = 5
            #expect(!UpdateService.verify(file, wrongSize))
            var wrongHash = good
            wrongHash.sha256 = String(repeating: "0", count: 64)
            #expect(!UpdateService.verify(file, wrongHash))
        }

        @Test func comparesVersions() {
            #expect(UpdateService.isNewer("1.2.0", than: "1.1.1"))
            #expect(!UpdateService.isNewer("1.2.0", than: "1.2.0"))
            #expect(!UpdateService.isNewer("1.1.9", than: "1.2.0"))
        }

        @Test func unparsableVersionIsNeverNewer() {
            // C#: UpdateManifest.ParsedVersion is null for "garbage", so IsNewer is false.
            #expect(!UpdateService.isNewer("garbage", than: "1.0"))
        }

        // Mac only
        @Test func numericComparisonOfDottedVersions() {
            #expect(UpdateService.isNewer("1.10.0", than: "1.9.9"))
            #expect(!UpdateService.isNewer("1.9.9", than: "1.10.0"))
            #expect(UpdateService.isNewer("2.0", than: "1.99.99"))
            #expect(UpdateService.isNewer("1.0.1", than: "1.0"))
        }

        @Test(.timeLimit(.minutes(1)))
        func downloadsFromALocalManifestAndDetectsFailedInstalls() async throws {
            try await withDataDirAsync { dir in
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let source = dir.appendingPathComponent("setup.zip")
                try Data([9, 8, 7]).write(to: source)
                let m = UpdateManifest(version: "2.0.0", url: source.path, sha256: Self.hex([9, 8, 7]), size: 3, notes: "notes")

                let installer = try await UpdateService.download(m)
                #expect(UpdateService.verify(installer, m))

                // A corrupt package is rejected after the retries.
                var corrupt = m
                corrupt.version = "2.0.1"
                corrupt.sha256 = String(repeating: "0", count: 64)
                await #expect(throws: (any Error).self) { _ = try await UpdateService.download(corrupt) }

                // Pending marker: still on the old version at next start → the install failed (rolled back).
                let marker = AppPaths.updatesDir.appendingPathComponent("pending.json")
                try FileManager.default.createDirectory(at: AppPaths.updatesDir, withIntermediateDirectories: true)
                let pending = #"{"version":"2.0.0","startedAt":"2026-10-25T00:00:00"}"#
                try pending.write(to: marker, atomically: true, encoding: .utf8)
                let failed = UpdateService.checkPendingResult(current: "1.9.0")
                #expect(failed.outcome == .failed)
                #expect(failed.version == "2.0.0")
                let again = UpdateService.checkPendingResult(current: "1.9.0") // reported once
                #expect(again.outcome == .none)
                #expect(again.version == nil)

                try pending.write(to: marker, atomically: true, encoding: .utf8)
                let ok = UpdateService.checkPendingResult(current: "2.0.0")
                #expect(ok.outcome == .succeeded)
                #expect(ok.version == "2.0.0")
            }
        }
    }
}
