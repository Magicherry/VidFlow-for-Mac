import Foundation
import Testing
@testable import VidFlowCore

extension VidFlowCoreTests {
    @Suite("DownloadStore")
    struct DownloadStoreTests {
        init() { TestEnv.prepare() }

        @Test func downloadListRoundTripsAndResumesRunningItems() throws {
            try withDataDir { _ in
                var running = DownloadRecord(request: DownloadRequest(url: "u", mode: "video", maxHeight: 720, writeSubtitles: false, outputFolder: "o"), title: "a")
                running.state = .downloading
                var done = DownloadRecord(request: DownloadRequest(url: "u2", mode: "mp3", maxHeight: 0, writeSubtitles: false, outputFolder: "o"), title: "b")
                done.state = .completed
                var processing = DownloadRecord(request: DownloadRequest(url: "u3", mode: "video", maxHeight: 0, writeSubtitles: false, outputFolder: "o"), title: "c")
                processing.state = .processing
                DownloadStore.save([running, done, processing])

                let loaded = DownloadStore.load()
                #expect(loaded.count == 3)
                #expect(loaded[0].state == .queued)
                #expect(loaded[0].request.maxHeight == 720)
                #expect(loaded[1].state == .completed)
                #expect(loaded[2].state == .queued)
            }
        }

        @Test func missingOrBrokenFileGivesAnEmptyList() throws {
            try withDataDir { dir in
                #expect(DownloadStore.load().isEmpty)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try "not json".write(to: dir.appendingPathComponent("downloads.json"), atomically: true, encoding: .utf8)
                #expect(DownloadStore.load().isEmpty)
            }
        }

        @Test func listsSavedByOlderVersionsStillLoad() throws {
            try withDataDir { dir in
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let json = #"[{"request":{"url":"u","mode":"video","outputFolder":"o"},"title":"old"}]"#
                try json.write(to: dir.appendingPathComponent("downloads.json"), atomically: true, encoding: .utf8)
                let r = try #require(DownloadStore.load().first)
                #expect(r.title == "old")
                #expect(r.state == .queued)
                #expect(r.request.codec == "auto")
                #expect(r.request.container == "mp4")
                #expect(r.request.fileNameTemplate == NamingTemplate.defaultFileName)
            }
        }
    }

    @Suite("Settings")
    struct SettingsMigrationTests {
        init() { TestEnv.prepare() }

        @Test func settingsFromAnOlderFileKeepTheirValuesAndDefaultTheRest() throws {
            let saved = SettingsStore.shared.current
            defer { SettingsStore.shared.current = saved }
            try withDataDir { dir in
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try #"{ "theme": "Dark", "maxConcurrent": 3 }"#.write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
                SettingsStore.shared.current = AppSettings()
                SettingsStore.shared.load()
                #expect(SettingsStore.shared.current.theme == "Dark")
                #expect(SettingsStore.shared.current.maxConcurrent == 3)
                #expect(SettingsStore.shared.current.embedChapters)
                #expect(SettingsStore.shared.current.subtitleLanguages == AppSettings().subtitleLanguages)

                SettingsStore.shared.current.language = ""
                SettingsStore.shared.save()
                SettingsStore.shared.load()
                #expect(SettingsStore.shared.current.language == "") // an explicit "follow the system" is kept
            }
        }

        @Test func settingsFromVersion1KeepChinese() throws {
            let saved = SettingsStore.shared.current
            defer { SettingsStore.shared.current = saved }
            try withDataDir { dir in
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try #"{ "theme": "Dark", "maxConcurrent": 3 }"#.write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
                SettingsStore.shared.current = AppSettings()
                SettingsStore.shared.load()
                // Windows moves files from its Chinese-only 1.0 to "zh"; there was never such a Mac version to migrate.
                #expect(SettingsStore.shared.current.language == "")
            }
        }

        @Test func unreadableFileKeepsCurrentSettings() throws {
            let saved = SettingsStore.shared.current
            defer { SettingsStore.shared.current = saved }
            try withDataDir { dir in
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try "{ nope".write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
                SettingsStore.shared.current = AppSettings()
                SettingsStore.shared.current.maxConcurrent = 5
                SettingsStore.shared.load()
                #expect(SettingsStore.shared.current.maxConcurrent == 5)
            }
        }
    }

    @Suite("TemplateStore")
    struct TemplateStoreTests {
        init() { L.apply(language: "en") }

        @Test func createEditDuplicateRenameDeleteAndDefault() throws {
            try withDataDir { _ in
                var store = TemplateStore()
                var settings = AppSettings()
                // nothing chosen yet
                #expect(store.defaultTemplate(settings).id == TemplateStore.builtIns[0].id)

                let mine = store.duplicate(TemplateStore.builtIns[2], name: "Mine")
                #expect(!mine.isBuiltIn)
                #expect(mine.codec == "h264")

                // Rename and set-as-default are plain edits in Swift: save the changed copy, point the setting at it.
                var edited = mine
                edited.container = "mkv"
                edited.name = "Renamed"
                store.save(edited)
                settings.defaultTemplateId = mine.id

                store = TemplateStore() // reload from disk
                let loaded = try #require(store.find(mine.id))
                #expect(loaded.displayName == "Renamed")
                #expect(loaded.container == "mkv")
                #expect(store.defaultTemplate(settings).id == mine.id)

                #expect(store.uniqueName("Renamed") == "Renamed (2)")
                // Built-in presets are read-only: saving one changes nothing.
                store.save(TemplateStore.builtIns[0])
                #expect(store.custom.count == 1)

                store.delete(loaded)
                #expect(store.find(mine.id) == nil)
                #expect(store.defaultTemplate(settings).id == TemplateStore.builtIns[0].id) // default falls back
                #expect(TemplateStore().custom.isEmpty)
            }
        }

        @Test func builtInPresetsCannotBeDeleted() throws {
            try withDataDir { _ in
                var store = TemplateStore()
                store.delete(TemplateStore.builtIns[1])
                #expect(store.find(TemplateStore.builtIns[1].id) != nil)
                #expect(store.all.count == TemplateStore.builtIns.count)
            }
        }

        @Test func templateCopyIsIndependentForPerTaskOverrides() {
            let t = TemplateStore.builtIns[1]
            var copy = t
            copy.maxHeight = 720
            #expect(t.maxHeight == 1080) // the preset is untouched
            #expect(!copy.sameOptions(as: t))
            let req = copy.toRequest(url: "https://youtu.be/x", baseFolder: "/out")
            #expect(req.maxHeight == 720)
            #expect(req.mode == "video")
        }
    }
}
