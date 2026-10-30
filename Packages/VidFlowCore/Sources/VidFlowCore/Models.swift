import Foundation

public enum Platform: String, Codable, CaseIterable, Sendable, Identifiable {
    case youTube = "YouTube", bilibili = "Bilibili", douyin = "Douyin", weibo = "Weibo"
    case xiaohongshu = "Xiaohongshu", x = "X", other = "Other"

    public var id: String { rawValue }

    /// The platforms VidFlow supports, in the order they are listed.
    public static let supported: [Platform] = [.bilibili, .douyin, .xiaohongshu, .weibo, .youTube, .x]

    public var displayName: String {
        switch self {
        case .youTube: "YouTube"
        case .x: "X"
        case .bilibili: L.get("Platform_Bilibili")
        case .douyin: L.get("Platform_Douyin")
        case .weibo: L.get("Platform_Weibo")
        case .xiaohongshu: L.get("Platform_Xiaohongshu")
        case .other: L.get("Platform_Other")
        }
    }
}

/// One selectable resolution, with what yt-dlp reported about it.
public struct QualityOption: Equatable, Hashable, Sendable {
    public var height: Int
    public var fps: Int
    public var estimatedBytes: Int64?
    public init(height: Int, fps: Int, estimatedBytes: Int64?) {
        self.height = height
        self.fps = fps
        self.estimatedBytes = estimatedBytes
    }
}

/// Result of parsing a link: either a single video or a playlist / multi-part video.
public enum MediaInfo: Sendable, Equatable {
    case video(VideoInfo)
    case playlist(PlaylistInfo)

    public var url: String {
        switch self { case .video(let v): v.url; case .playlist(let p): p.url }
    }
    public var title: String {
        switch self { case .video(let v): v.title; case .playlist(let p): p.title }
    }
    public var uploader: String? {
        switch self { case .video(let v): v.uploader; case .playlist(let p): p.uploader }
    }
    public var thumbnailURL: String? {
        switch self { case .video(let v): v.thumbnailURL; case .playlist(let p): p.thumbnailURL }
    }
    public var platform: Platform {
        switch self { case .video(let v): v.platform; case .playlist(let p): p.platform }
    }
}

public struct VideoInfo: Sendable, Equatable {
    public var url: String
    public var title: String
    public var uploader: String?
    public var thumbnailURL: String?
    public var platform: Platform = .other
    public var duration: Double?
    public var uploadDate: String?
    /// Available resolutions, highest first.
    public var qualities: [QualityOption] = []
    /// Estimated size of the best audio-only stream (for audio downloads).
    public var audioBytes: Int64?
    /// Video codecs offered (see `VideoCodecs`) and the highest resolution available in each.
    public var codecs: [String: Int] = [:]
    /// Audio track languages offered (YouTube multi-language audio); the original track first.
    public var audioLanguages: [String] = []
    /// High dynamic range kinds offered ("DV", "HDR10", "HDR10+", "HLG"), best first; empty when SDR only.
    public var hdrKinds: [String] = []
    /// A Hi-Res lossless (FLAC) audio track is offered (Bilibili, with membership).
    public var hasHiRes = false
    /// A Dolby Atmos (E-AC-3) audio track is offered (Bilibili).
    public var hasAtmos = false

    public init(url: String, title: String) {
        self.url = url
        self.title = title
    }

    public var hasHdr: Bool { hdrKinds.contains { $0 != "DV" } }
    public var hasDolbyVision: Bool { hdrKinds.contains("DV") }

    /// Badges for the preview: picture kinds first, then sound.
    public var features: [String] {
        hdrKinds + (hasHiRes ? [MediaFeatures.hiRes] : []) + (hasAtmos ? [MediaFeatures.atmos] : [])
    }
}

public struct PlaylistInfo: Sendable, Equatable {
    public var url: String
    public var title: String
    public var uploader: String?
    public var thumbnailURL: String?
    public var platform: Platform = .other
    public var entries: [PlaylistEntry] = []

    public init(url: String, title: String) {
        self.url = url
        self.title = title
    }
}

public struct PlaylistEntry: Sendable, Equatable, Identifiable {
    public var index: Int
    public var url: String
    public var title: String
    public var duration: Double?
    public var thumbnailURL: String?
    public var id: Int { index }

    public init(index: Int, url: String, title: String, duration: Double? = nil, thumbnailURL: String? = nil) {
        self.index = index
        self.url = url
        self.title = title
        self.duration = duration
        self.thumbnailURL = thumbnailURL
    }
}

/// What the user chose to download. Usually produced from a `DownloadTemplate`; every field but the first few has a
/// default so download lists saved by older versions still load.
public struct DownloadRequest: Codable, Equatable, Sendable {
    public var url: String
    public var mode: String                 // video | audio | cover (older lists may contain mp3 / m4a, meaning audio)
    public var maxHeight: Int               // 0 = best
    public var writeSubtitles: Bool
    public var outputFolder: String         // base folder; folderTemplate subfolders go inside it
    public var codec = "auto"               // auto, h264, h265, av1, vp9 (see VideoCodecs)
    public var container = "mp4"            // mp4, mkv, webm
    public var audioFormat = "auto"         // video: auto / aac / opus;  audio: mp3 / m4a / opus / flac / wav
    public var audioQuality = 0             // kbps; 0 = best
    public var audioLanguage = ""           // "" = default (original) track, else a language code
    public var recode = false               // re-encode when the streams don't fit the container
    public var fileNameTemplate = NamingTemplate.defaultFileName
    public var folderTemplate = ""
    public var dynamicRange = MediaFeatures.auto // auto, dv, sdr (see MediaFeatures)
    public var overwrite = false            // replace a file that already exists (the user asked to download it again)

    public init(url: String, mode: String, maxHeight: Int, writeSubtitles: Bool, outputFolder: String,
                codec: String = "auto", container: String = "mp4", audioFormat: String = "auto", audioQuality: Int = 0,
                audioLanguage: String = "", recode: Bool = false,
                fileNameTemplate: String = NamingTemplate.defaultFileName, folderTemplate: String = "",
                dynamicRange: String = MediaFeatures.auto) {
        self.url = url
        self.mode = mode
        self.maxHeight = maxHeight
        self.writeSubtitles = writeSubtitles
        self.outputFolder = outputFolder
        self.codec = codec
        self.container = container
        self.audioFormat = audioFormat
        self.audioQuality = audioQuality
        self.audioLanguage = audioLanguage
        self.recode = recode
        self.fileNameTemplate = fileNameTemplate
        self.folderTemplate = folderTemplate
        self.dynamicRange = dynamicRange
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        mode = try c.decode(String.self, forKey: .mode)
        maxHeight = try c.decodeIfPresent(Int.self, forKey: .maxHeight) ?? 0
        writeSubtitles = try c.decodeIfPresent(Bool.self, forKey: .writeSubtitles) ?? false
        outputFolder = try c.decode(String.self, forKey: .outputFolder)
        codec = try c.decodeIfPresent(String.self, forKey: .codec) ?? "auto"
        container = try c.decodeIfPresent(String.self, forKey: .container) ?? "mp4"
        audioFormat = try c.decodeIfPresent(String.self, forKey: .audioFormat) ?? "auto"
        audioQuality = try c.decodeIfPresent(Int.self, forKey: .audioQuality) ?? 0
        audioLanguage = try c.decodeIfPresent(String.self, forKey: .audioLanguage) ?? ""
        recode = try c.decodeIfPresent(Bool.self, forKey: .recode) ?? false
        fileNameTemplate = try c.decodeIfPresent(String.self, forKey: .fileNameTemplate) ?? NamingTemplate.defaultFileName
        folderTemplate = try c.decodeIfPresent(String.self, forKey: .folderTemplate) ?? ""
        dynamicRange = try c.decodeIfPresent(String.self, forKey: .dynamicRange) ?? MediaFeatures.auto
        overwrite = try c.decodeIfPresent(Bool.self, forKey: .overwrite) ?? false
    }

    public var isAudio: Bool { mode == "audio" || mode == "mp3" || mode == "m4a" }

    /// Only the cover (thumbnail) image, saved as JPG when ffmpeg can convert it.
    public var isCover: Bool { mode == "cover" }

    /// Output format for audio-only downloads ("best" keeps the source's own format).
    public var audioOutputFormat: String {
        if mode == "mp3" || mode == "m4a" { return mode }
        return ["mp3", "m4a", "opus", "flac", "wav", MediaFeatures.original].contains(audioFormat) ? audioFormat : "mp3"
    }

    /// The picture or sound chosen can't go in MP4 (yt-dlp would merge into MKV anyway): say MKV up front.
    public var needsMkv: Bool {
        !isAudio && !isCover && (dynamicRange == MediaFeatures.dolbyVision || audioFormat == MediaFeatures.hiRes)
    }
}

/// A reusable set of download options. Built-in presets are read-only (duplicate them to customize); the user's own
/// templates are stored in templates.json. The home page edits a copy, so a per-task change never alters the template.
public struct DownloadTemplate: Codable, Equatable, Identifiable, Sendable, Hashable {
    public var id = UUID()
    /// Name of a user template.
    public var name = ""
    /// Localization key for built-in presets (their name follows the UI language).
    public var nameKey: String?
    public var mode = "video"            // video | audio | cover
    public var maxHeight = 0             // 0 = best (original)
    public var codec = VideoCodecs.auto
    /// Picture: auto (HDR when offered), dv (Dolby Vision) or sdr. See `MediaFeatures`.
    public var dynamicRange = MediaFeatures.auto
    public var container = "mp4"
    public var audioFormat = "auto"
    public var audioQuality = 0
    public var audioLanguage = ""
    public var recode = false
    public var subtitles = false
    public var fileNameTemplate = NamingTemplate.defaultFileName
    public var folderTemplate = ""

    public init(id: UUID = UUID(), name: String = "", nameKey: String? = nil, mode: String = "video", maxHeight: Int = 0,
                codec: String = VideoCodecs.auto, audioFormat: String = "auto", audioQuality: Int = 0) {
        self.id = id
        self.name = name
        self.nameKey = nameKey
        self.mode = mode
        self.maxHeight = maxHeight
        self.codec = codec
        self.audioFormat = audioFormat
        self.audioQuality = audioQuality
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        nameKey = try c.decodeIfPresent(String.self, forKey: .nameKey)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "video"
        maxHeight = try c.decodeIfPresent(Int.self, forKey: .maxHeight) ?? 0
        codec = try c.decodeIfPresent(String.self, forKey: .codec) ?? VideoCodecs.auto
        dynamicRange = try c.decodeIfPresent(String.self, forKey: .dynamicRange) ?? MediaFeatures.auto
        container = try c.decodeIfPresent(String.self, forKey: .container) ?? "mp4"
        audioFormat = try c.decodeIfPresent(String.self, forKey: .audioFormat) ?? "auto"
        audioQuality = try c.decodeIfPresent(Int.self, forKey: .audioQuality) ?? 0
        audioLanguage = try c.decodeIfPresent(String.self, forKey: .audioLanguage) ?? ""
        recode = try c.decodeIfPresent(Bool.self, forKey: .recode) ?? false
        subtitles = try c.decodeIfPresent(Bool.self, forKey: .subtitles) ?? false
        fileNameTemplate = try c.decodeIfPresent(String.self, forKey: .fileNameTemplate) ?? NamingTemplate.defaultFileName
        folderTemplate = try c.decodeIfPresent(String.self, forKey: .folderTemplate) ?? ""
    }

    public var isBuiltIn: Bool { nameKey != nil }
    public var displayName: String { nameKey.map(L.get) ?? name }

    /// True when the download options (not the name) are the same.
    public func sameOptions(as o: DownloadTemplate) -> Bool {
        mode == o.mode && maxHeight == o.maxHeight && codec == o.codec && dynamicRange == o.dynamicRange
            && container == o.container && audioFormat == o.audioFormat && audioQuality == o.audioQuality
            && audioLanguage == o.audioLanguage && recode == o.recode && subtitles == o.subtitles
            && fileNameTemplate == o.fileNameTemplate && folderTemplate == o.folderTemplate
    }

    public func toRequest(url: String, baseFolder: String) -> DownloadRequest {
        DownloadRequest(url: url, mode: mode == "audio" || mode == "cover" ? mode : "video",
                        maxHeight: mode == "video" ? maxHeight : 0, writeSubtitles: subtitles && mode != "cover",
                        outputFolder: baseFolder, codec: codec, container: container, audioFormat: audioFormat,
                        audioQuality: audioQuality, audioLanguage: audioLanguage, recode: recode,
                        fileNameTemplate: fileNameTemplate, folderTemplate: folderTemplate, dynamicRange: dynamicRange)
    }
}

public enum DownloadState: String, Codable, Sendable {
    case queued = "Queued", downloading = "Downloading", processing = "Processing", completed = "Completed"
    case failed = "Failed", canceled = "Canceled", paused = "Paused"
}

/// Persisted form of a download, so the list and unfinished work survive restarts.
public struct DownloadRecord: Codable, Identifiable, Sendable, Equatable {
    public var id = UUID()
    public var request: DownloadRequest
    public var title: String
    public var thumbnailURL: String?
    /// Position in a playlist / multi-part video, shown as "P3".
    public var partIndex: Int?
    public var state: DownloadState = .queued
    public var filePath: String?
    public var statusText: String?
    public var errorDetail: String?
    public var createdAt = Date()
    /// Set by "download next": queued items with a later value start first.
    public var priorityAt: Date?
    /// Last known overall percentage, so a paused or resumed row doesn't restart from zero.
    public var progress: Double = 0
    /// Where yt-dlp said the file will end up, known once it starts: how the working files are found again.
    public var expectedPath: String?

    public init(request: DownloadRequest, title: String, thumbnailURL: String? = nil, partIndex: Int? = nil) {
        self.request = request
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.partIndex = partIndex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        request = try c.decode(DownloadRequest.self, forKey: .request)
        title = try c.decode(String.self, forKey: .title)
        thumbnailURL = try c.decodeIfPresent(String.self, forKey: .thumbnailURL)
        partIndex = try c.decodeIfPresent(Int.self, forKey: .partIndex)
        state = try c.decodeIfPresent(DownloadState.self, forKey: .state) ?? .queued
        filePath = try c.decodeIfPresent(String.self, forKey: .filePath)
        statusText = try c.decodeIfPresent(String.self, forKey: .statusText)
        errorDetail = try c.decodeIfPresent(String.self, forKey: .errorDetail)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        priorityAt = try c.decodeIfPresent(Date.self, forKey: .priorityAt)
        progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        expectedPath = try c.decodeIfPresent(String.self, forKey: .expectedPath)
    }
}
