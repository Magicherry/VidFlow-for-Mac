import Foundation

/// User preferences, persisted as JSON under Application Support/VidFlow.
public struct AppSettings: Codable, Equatable, Sendable {
    public var downloadFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads/VidFlow", isDirectory: true).path
    /// System, Light or Dark.
    public var theme = "System"
    /// "" follows the system; otherwise "zh" or "en". Applied on next start.
    public var language = ""
    public var maxConcurrent = 2
    /// Per-download speed limit in KB/s; 0 means unlimited.
    public var speedLimitKBps = 0
    /// Download each file over several connections (aria2c), when aria2 is installed.
    public var multiConnection = true
    /// The limit last entered, restored when the limit is switched back on.
    public var speedLimitValueKBps = 5 * 1024
    public var preferH264 = false
    public var embedMetadata = true
    /// Embed the video's chapters (YouTube's, Bilibili's…) so players can jump between them.
    public var embedChapters = true
    /// SponsorBlock on YouTube videos (see SponsorBlockModes): off, mark segments as chapters, or cut them out.
    public var sponsorBlock = "off"
    /// yt-dlp --sub-langs value.
    public var subtitleLanguages = "zh-Hans,zh-Hant,zh-CN,zh-TW,zh,ai-zh,en"
    /// Also save Bilibili danmaku (bullet comments) as XML when subtitles are on.
    public var saveDanmaku = false
    /// Browser to read cookies from (chrome, safari, firefox…); empty to disable.
    public var cookiesBrowser = ""
    public var cookiesFile = ""
    public var proxy = ""
    /// Template new downloads start from (see TemplateStore).
    public var defaultTemplateId: UUID?
    /// App updates: auto (download, then ask to install), notify (only tell), manual (only when asked).
    public var updateMode = "auto"
    public var lastUpdateCheck: Date?
    public var watchClipboard = false
    public var notifyOnFinish = true
    /// Notify about failed or stalled downloads.
    public var notifyOnFailure = true
    /// Show VidFlow's status item in the menu bar.
    public var showMenuBarItem = false
    /// Update VidFlow's own copies of the components in the background.
    public var autoUpdateComponents = true
    /// Last completed automatic component update check.
    public var lastComponentUpdateCheck: Date?
    public var firstRunCompleted = false

    public init() {}
}

/// JSON files that keep working across versions: fields missing from an older file take their defaults.
enum JSONFile {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Written to a temporary file first, so a crash can't leave half a file behind.
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try AppPaths.ensureDirectory(url.deletingLastPathComponent())
        try encoder().encode(value).write(to: url, options: .atomic)
    }

    /// Top-level fields of `data` laid over `defaults`.
    static func decode<T: Codable>(_ data: Data, defaults: T) throws -> T {
        let base = try JSONSerialization.jsonObject(with: encoder().encode(defaults)) as? [String: Any] ?? [:]
        let stored = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let merged = base.merging(stored) { _, new in new }
        return try decoder().decode(T.self, from: JSONSerialization.data(withJSONObject: merged))
    }
}

public final class SettingsStore: @unchecked Sendable {
    public static let shared = SettingsStore()
    private let state = Locked(AppSettings())

    private var fileURL: URL { AppPaths.dataDir.appendingPathComponent("settings.json") }

    public var current: AppSettings {
        get { state.current }
        set { state.current = newValue }
    }

    public func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            state.current = try JSONFile.decode(data, defaults: AppSettings())
        } catch {
            Log.warn("Settings could not be read, using defaults: \(error.localizedDescription)")
        }
    }

    public func save() {
        do {
            try JSONFile.write(state.current, to: fileURL)
        } catch {
            // Settings are a convenience; failing to persist them must not crash the app.
            Log.warn("Settings could not be saved: \(error.localizedDescription)")
        }
    }
}

/// Reads and writes the download list (downloads.json).
public enum DownloadStore {
    private static var fileURL: URL { AppPaths.dataDir.appendingPathComponent("downloads.json") }

    public static func load() -> [DownloadRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            var records = try JSONFile.decoder().decode([DownloadRecord].self, from: data)
            // Anything that was running when the app closed is resumed from where it stopped.
            for i in records.indices where records[i].state == .downloading || records[i].state == .processing {
                records[i].state = .queued
            }
            return records
        } catch {
            Log.warn("Download list could not be read: \(error.localizedDescription)")
            return []
        }
    }

    public static func save(_ records: [DownloadRecord]) {
        do {
            try JSONFile.write(records, to: fileURL)
        } catch {
            Log.warn("Download list could not be saved: \(error.localizedDescription)")
        }
    }
}

/// Built-in download presets plus the user's templates (templates.json).
public struct TemplateStore: Sendable {
    /// Fixed ids so "default template" survives restarts and language changes.
    public static let builtIns: [DownloadTemplate] = [
        DownloadTemplate(id: UUID(uuidString: "6f1d6c2e-0001-4000-8000-000000000001")!, nameKey: "Preset_Best"),
        DownloadTemplate(id: UUID(uuidString: "6f1d6c2e-0002-4000-8000-000000000002")!, nameKey: "Preset_HD", maxHeight: 1080),
        DownloadTemplate(id: UUID(uuidString: "6f1d6c2e-0003-4000-8000-000000000003")!, nameKey: "Preset_Compatible", maxHeight: 1080, codec: "h264", audioFormat: "aac"),
        DownloadTemplate(id: UUID(uuidString: "6f1d6c2e-0004-4000-8000-000000000004")!, nameKey: "Preset_SaveSpace", maxHeight: 720, codec: "h265", audioQuality: 128),
        DownloadTemplate(id: UUID(uuidString: "6f1d6c2e-0005-4000-8000-000000000005")!, nameKey: "Preset_AudioOnly", mode: "audio", audioFormat: "mp3"),
    ]

    public private(set) var custom: [DownloadTemplate]

    private static var fileURL: URL { AppPaths.dataDir.appendingPathComponent("templates.json") }

    public init() {
        custom = []
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        do {
            custom = try JSONFile.decoder().decode([DownloadTemplate].self, from: data)
        } catch {
            Log.warn("Templates could not be read: \(error.localizedDescription)")
        }
    }

    public var all: [DownloadTemplate] { Self.builtIns + custom }

    public func find(_ id: UUID?) -> DownloadTemplate? { all.first { $0.id == id } }

    /// The template new downloads start from (falls back to "Best quality").
    public func defaultTemplate(_ settings: AppSettings) -> DownloadTemplate { find(settings.defaultTemplateId) ?? Self.builtIns[0] }

    /// Adds a new user template (or replaces the one with the same id).
    public mutating func save(_ t: DownloadTemplate) {
        guard !t.isBuiltIn else { return }
        if let i = custom.firstIndex(where: { $0.id == t.id }) { custom[i] = t } else { custom.append(t) }
        persist()
    }

    @discardableResult
    public mutating func duplicate(_ source: DownloadTemplate, name: String) -> DownloadTemplate {
        var copy = source
        copy.id = UUID()
        copy.nameKey = nil
        copy.name = name
        save(copy)
        return copy
    }

    public mutating func delete(_ t: DownloadTemplate) {
        guard !t.isBuiltIn else { return }
        custom.removeAll { $0.id == t.id }
        persist()
    }

    /// "Name", "Name (2)", ... avoiding names already used.
    public func uniqueName(_ base: String) -> String {
        let names = Set(all.map { $0.displayName.lowercased() })
        if !names.contains(base.lowercased()) { return base }
        var n = 2
        while names.contains("\(base) (\(n))".lowercased()) { n += 1 }
        return "\(base) (\(n))"
    }

    private func persist() {
        do {
            try JSONFile.write(custom, to: Self.fileURL)
        } catch {
            Log.warn("Templates could not be saved: \(error.localizedDescription)")
        }
    }
}
