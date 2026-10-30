import Foundation

/// Video codec choices: "auto" (best quality, any codec), "h264", "h265", "av1", "vp9".
public enum VideoCodecs {
    public static let auto = "auto"

    /// In the order offered to the user (most compatible first).
    public static let all = ["h264", "h265", "av1", "vp9"]

    /// Maps a yt-dlp vcodec string ("avc1.640032", "hev1.1.6…", "av01.0.08M.08", "vp09.00…", "vp9") to a choice.
    public static func family(_ vcodec: String?) -> String? {
        let v = vcodec?.lowercased() ?? ""
        if v.hasPrefix("avc") || v.hasPrefix("h264") { return "h264" }
        // Dolby Vision streams are named after their base codec: dvh1 / dvhe (HEVC), dav1 (AV1).
        if v.hasPrefix("hev") || v.hasPrefix("hvc") || v.hasPrefix("h265") || v.hasPrefix("dvh") { return "h265" }
        if v.hasPrefix("av01") || v == "av1" || v.hasPrefix("dav1") { return "av1" }
        if v.hasPrefix("vp09") || v.hasPrefix("vp9") { return "vp9" }
        return nil
    }

    /// yt-dlp format filter selecting video streams of the codec ("" for auto).
    public static func filter(_ codec: String) -> String {
        switch codec {
        case "h264": "[vcodec~='^(avc|h264)']"
        case "h265": "[vcodec~='^(hev|hvc|h265|dvh)']"
        case "av1": "[vcodec~='^(av01|dav1)']"
        case "vp9": "[vcodec~='^vp0?9']"
        default: ""
        }
    }

    public static func displayName(_ codec: String) -> String {
        switch codec {
        case "h264": "H.264 (AVC)"
        case "h265": "H.265 (HEVC)"
        case "av1": "AV1"
        case "vp9": "VP9"
        default: L.get("Codec_Auto")
        }
    }

    /// Short form for list labels: "H.264".
    public static func shortName(_ codec: String) -> String {
        switch codec {
        case "h264": "H.264"
        case "h265": "H.265"
        case "av1": "AV1"
        case "vp9": "VP9"
        default: ""
        }
    }
}

/// High-end picture and sound: HDR (HDR10 / HDR10+ / HLG), Dolby Vision, Hi-Res lossless (FLAC) and Dolby Atmos
/// (E-AC-3). Recognising them in yt-dlp's format list, the choices offered, and how a choice steers yt-dlp.
public enum MediaFeatures {
    /// HDR10 / HLG when offered, otherwise SDR; not Dolby Vision (see `dolbyVision`).
    public static let auto = "auto"
    /// Dolby Vision when offered. Not the default: Bilibili's profile 5 has no HDR10 base layer, so players without
    /// Dolby Vision support show it with green / purple colours.
    public static let dolbyVision = "dv"
    /// Standard dynamic range, for ordinary screens and players.
    public static let sdr = "sdr"
    public static let pictures = [auto, dolbyVision, sdr]

    /// yt-dlp's "hdr" sort field (DV > HDR12 > HDR10+ > HDR10 > HLG > SDR), capped per choice.
    /// Compatibility mode (H.264) means SDR: H.264 is practically never HDR.
    public static func hdrSort(_ picture: String, compatibilityMode: Bool) -> String {
        if picture == dolbyVision { return "hdr" }
        if picture == sdr || compatibilityMode { return "hdr:SDR" }
        return "hdr:HDR10"
    }

    public static let hiRes = "hires"
    public static let atmos = "atmos"
    /// Audio-only output that keeps the source as it is (FLAC stays FLAC).
    public static let original = "best"

    public static func isHiResCodec(_ acodec: String?) -> Bool {
        let a = acodec?.lowercased()
        return a == "flac" || a == "alac"
    }

    /// The audio-only output for "original": the source codec in its own file type (FLAC → .flac, AAC → .m4a,
    /// Opus → .opus, MP3 → .mp3), so nothing is re-encoded; anything else is left to yt-dlp ("best").
    public static func originalOutput(_ acodec: String?) -> String {
        guard let a = acodec?.trimmingCharacters(in: .whitespaces).lowercased() else { return original }
        if a == "flac" || a == "alac" { return "flac" }
        if a == "opus" { return "opus" }
        if a == "mp3" { return "mp3" }
        if a.hasPrefix("mp4a") || a.hasPrefix("aac") { return "m4a" }
        return original
    }

    public static func isAtmosCodec(_ acodec: String?) -> Bool {
        guard let a = acodec?.lowercased() else { return false }
        return a.hasPrefix("ec-3") || a.hasPrefix("eac3") || a.hasPrefix("ac-4")
    }

    /// yt-dlp's dynamic_range values ("HDR10", "DV", …), or nil for SDR / unknown.
    public static func hdrKind(_ dynamicRange: String?) -> String? {
        guard let d = dynamicRange, !d.isEmpty, d.caseInsensitiveCompare("SDR") != .orderedSame else { return nil }
        return d.uppercased()
    }

    public static func label(_ feature: String) -> String {
        switch feature {
        case "DV": L.get("Feature_DolbyVision")
        case hiRes: L.get("Feature_HiRes")
        case atmos: L.get("Feature_Atmos")
        default: feature // HDR10, HDR10+, HLG, HDR12 read the same in every language
        }
    }
}

/// What to do with SponsorBlock segments (sponsor reads, self-promotion, intros…) in YouTube videos.
public enum SponsorBlockModes {
    public static let off = "off"
    /// Keep everything; the segments become chapters to skip by hand.
    public static let mark = "mark"
    /// Cut the segments out of the file.
    public static let remove = "remove"
    /// Cut: sponsor reads, self-promotion, "like and subscribe", intro and outro. Kept: off-topic parts,
    /// previews/recaps and filler, which viewers often want.
    public static let removedCategories = "sponsor,selfpromo,interaction,intro,outro"
}

/// A problem with the chosen container / codec combination and the suggested fix.
public struct CompatibilityIssue: Equatable, Sendable {
    /// Localization key of the explanation.
    public var messageKey: String
    /// Container that would work as-is, if switching is the fix.
    public var suggestedContainer: String?
    /// Audio format that would work as-is, if switching is the fix.
    public var suggestedAudioFormat: String?
    /// Not a problem, just what will happen (e.g. "saved as MKV"): shown as information, not a warning.
    public var info = false
}

/// Which codecs each container can hold. Downloads never fail over it (yt-dlp falls back to MKV, or re-encodes when
/// "convert automatically" is on); this is to warn and recommend in the UI before downloading.
public enum FormatCompatibility {
    public static let containers = ["mp4", "mkv", "webm"]

    /// - Parameter video: The parsed video, when known: what it offers (HDR, Hi-Res) changes the advice.
    public static func check(_ t: DownloadTemplate, video: VideoInfo? = nil) -> CompatibilityIssue? {
        if t.mode == "cover" { return nil }
        if t.mode == "audio" {
            let hiRes = video?.hasHiRes == true
            if t.audioFormat == "flac" || t.audioFormat == "wav" {
                return hiRes ? nil : CompatibilityIssue(messageKey: "Compat_LosslessFromLossy")
            }
            // A lossy output from a Hi-Res source throws the lossless track away.
            return hiRes && t.audioFormat != MediaFeatures.original
                ? CompatibilityIssue(messageKey: "Compat_HiResAvailable", suggestedAudioFormat: "flac") : nil
        }
        if t.container != "mkv" {
            // Dolby Vision and Hi-Res FLAC only fit MKV; downloads go there automatically, so this is just a heads-up.
            if t.dynamicRange == MediaFeatures.dolbyVision || t.audioFormat == MediaFeatures.hiRes {
                return CompatibilityIssue(messageKey: "Compat_SavedAsMkv", suggestedContainer: "mkv", info: true)
            }
            // HDR is mostly VP9 / AV1 / HEVC with 10-bit colour, which yt-dlp usually can't merge into MP4.
            if video?.hasHdr == true, t.dynamicRange == MediaFeatures.auto, t.container == "mp4" {
                return CompatibilityIssue(messageKey: "Compat_HdrMkv", suggestedContainer: "mkv", info: true)
            }
        }
        if t.container == "webm" {
            if t.codec == "h264" || t.codec == "h265" {
                return CompatibilityIssue(messageKey: "Compat_WebmVideo", suggestedContainer: "mkv")
            }
            if t.audioFormat == "aac" {
                return CompatibilityIssue(messageKey: "Compat_WebmAudio", suggestedAudioFormat: "opus")
            }
        }
        if t.container == "mp4", t.audioFormat == "opus" {
            return CompatibilityIssue(messageKey: "Compat_Mp4Opus", suggestedAudioFormat: "aac")
        }
        return nil
    }

    /// yt-dlp --merge-output-format: the chosen container, falling back to MKV (which holds anything) when the
    /// selected streams don't fit it.
    public static func mergeFormats(_ container: String) -> String {
        switch container {
        case "mkv": "mkv"
        case "webm": "webm/mkv"
        default: "mp4/mkv"
        }
    }
}

/// Maps the yt-dlp `--sub-langs` setting to a short list of common languages the user can tick, plus any other codes
/// kept as typed. A language counts as chosen when any of its codes is present.
public enum SubtitleLanguageSet {
    /// Key, name in its own language, and the codes written for it (sites use different ones).
    public struct Language: Sendable, Identifiable {
        public var key: String
        public var nativeName: String
        public var codes: [String]
        public var id: String { key }
    }

    public static let common: [Language] = [
        // Bilibili's AI-generated subtitles are "ai-zh".
        Language(key: "zh-Hans", nativeName: "简体中文", codes: ["zh-Hans", "zh-CN", "zh", "ai-zh"]),
        Language(key: "zh-Hant", nativeName: "繁體中文", codes: ["zh-Hant", "zh-TW", "zh-HK"]),
        Language(key: "en", nativeName: "English", codes: ["en.*"]),
        Language(key: "ja", nativeName: "日本語", codes: ["ja.*"]),
        Language(key: "ko", nativeName: "한국어", codes: ["ko.*"]),
    ]

    /// Used by yt-dlp when nothing is chosen.
    public static let fallback = "zh.*,en.*"

    /// Splits a setting into the ticked common languages and the remaining codes.
    public static func split(_ setting: String) -> (chosen: Set<String>, other: String) {
        var chosen = Set<String>()
        var other: [String] = []
        for code in codes(setting) {
            if let lang = common.first(where: { matches($0, code) }) {
                chosen.insert(lang.key)
            } else if !other.contains(where: { $0.caseInsensitiveCompare(code) == .orderedSame }) {
                other.append(code)
            }
        }
        return (chosen, other.joined(separator: ", "))
    }

    /// The setting for the ticked languages plus the other codes (comma or space separated).
    public static func join(chosen: Set<String>, other: String) -> String {
        var result = common.filter { chosen.contains($0.key) }.flatMap(\.codes)
        for code in codes(other) where !result.contains(where: { $0.caseInsensitiveCompare(code) == .orderedSame }) {
            result.append(code)
        }
        return result.joined(separator: ",")
    }

    /// "简体中文, English" for a summary line; empty when nothing is chosen.
    public static func describe(_ setting: String) -> String {
        let (chosen, other) = split(setting)
        var names = common.filter { chosen.contains($0.key) }.map(\.nativeName)
        if !other.isEmpty { names.append(other) }
        return names.joined(separator: ", ")
    }

    private static func codes(_ text: String) -> [String] {
        text.split(whereSeparator: { ",， ;".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// "en", "en-US" and "en.*" all belong to English; "zh-CN" belongs to Simplified Chinese.
    private static func matches(_ lang: Language, _ code: String) -> Bool {
        for c in lang.codes {
            if c.caseInsensitiveCompare(code) == .orderedSame { return true }
            if c.hasSuffix(".*") {
                let prefix = String(c.dropLast(2))
                if code.caseInsensitiveCompare(prefix) == .orderedSame
                    || code.lowercased().hasPrefix(prefix.lowercased() + "-") { return true }
            }
        }
        return false
    }
}

/// File naming and folder classification rules made of variables such as {title} and {date}, translated into a yt-dlp
/// output template. The values are filled in by yt-dlp (and sanitized by it); literal text is cleaned here.
public enum NamingTemplate {
    public static let defaultFileName = "{title} [{id}]"

    /// File name presets (shown in the template editor); anything else is a custom pattern.
    public static let filePresets = [defaultFileName, "{title}", "{uploader} - {title}", "{date} {title}", "{title} ({resolution})"]

    /// Folder classification presets (shown in the template editor).
    public static let folderPresets = ["", "{platform}", "{uploader}", "{year}-{month}", "{platform}/{uploader}"]

    public static let variables = ["title", "uploader", "date", "year", "month", "resolution", "id", "platform"]

    /// Variable → yt-dlp field. {platform} is substituted before (it is known from the URL).
    private static let fields: [String: String] = [
        "title": "%(title).150B",
        "uploader": "%(uploader,channel,creator|Unknown)s",
        "date": "%(upload_date>%Y-%m-%d|unknown)s",
        "year": "%(upload_date>%Y|unknown)s",
        "month": "%(upload_date>%m|00)s",
        "resolution": "%(height&{}p|audio)s",
        "id": "%(id)s",
    ]

    private static let variableRegex = RX.make(#"\{([a-z]+)\}"#)

    /// Variables used in the pattern that VidFlow doesn't know (they would be kept as literal text).
    public static func unknownVariables(_ template: String) -> [String] {
        var seen: [String] = []
        forEachVariable(template) { _, name in
            if !variables.contains(name), !seen.contains(name) { seen.append(name) }
        }
        return seen
    }

    private static func forEachVariable(_ template: String, _ body: (NSRange, String) -> Void) {
        let ns = template as NSString
        for m in variableRegex.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            body(m.range, ns.substring(with: m.range(at: 1)))
        }
    }

    /// The yt-dlp "-o" value: optional folders, then the file name, then the extension. `known` supplies values
    /// VidFlow already has (when yt-dlp is only given a bare media address and wouldn't know the title or uploader);
    /// the rest are left to yt-dlp.
    public static func toOutputTemplate(fileTemplate: String, folderTemplate: String, platformName: String,
                                        known: [String: String?]? = nil) -> String {
        let blank = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var file = translate(blank(fileTemplate) ? defaultFileName : fileTemplate, platformName, false, known)
        if blank(file) { file = translate(defaultFileName, platformName, false, known) }
        let folder = blank(folderTemplate) ? "" : translate(folderTemplate, platformName, true, known)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (folder.isEmpty ? "" : folder + "/") + file + ".%(ext)s"
    }

    private static func translate(_ template: String, _ platformName: String, _ allowFolders: Bool,
                                  _ known: [String: String?]?) -> String {
        let ns = template as NSString
        var out = ""
        var last = 0
        forEachVariable(template) { range, name in
            out += literal(ns.substring(with: NSRange(location: last, length: range.location - last)), allowFolders)
            if name == "platform" {
                out += literal(platformName, false)
            } else if let known, let value = known[name] {
                out += literal(clip(value ?? "", 150), false)
            } else if let field = fields[name] {
                out += field
            } else {
                out += literal(ns.substring(with: range), allowFolders) // unknown variable: keep as text
            }
            last = range.location + range.length
        }
        out += literal(ns.substring(from: last), allowFolders)
        return out
    }

    /// At most `max` characters (Douyin captions can be long), on one line.
    private static func clip(_ s: String, _ max: Int) -> String {
        let line = s.split(whereSeparator: { $0.isNewline || $0 == "\t" }).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard line.count > max else { return line }
        var clipped = String(line.prefix(max))
        while clipped.last?.isWhitespace == true { clipped.removeLast() }
        return clipped
    }

    /// Literal text: no characters that trouble file names on either system, and "%" escaped for yt-dlp.
    private static func literal(_ text: String, _ allowFolders: Bool) -> String {
        var out = ""
        for c in text {
            switch c {
            case "/", "\\": out.append(allowFolders ? "/" : "_")
            case "<", ">", ":", "\"", "|", "?", "*": out.append("_")
            case "%": out += "%%"
            default:
                if c.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) { out.append("_") } else { out.append(c) }
            }
        }
        return out
    }

    /// Example result for the editor, e.g. "YouTube/Blender/Big Buck Bunny [aqz-KE-bpKQ].mp4".
    public static func preview(fileTemplate: String, folderTemplate: String, ext: String = "mp4") -> String {
        let sample = ["title": "Big Buck Bunny", "uploader": "Blender", "date": "2014-11-10", "year": "2014",
                      "month": "11", "resolution": "1080p", "id": "aqz-KE-bpKQ", "platform": "YouTube"]
        func fill(_ t: String, folders: Bool) -> String {
            let ns = t as NSString
            var out = ""
            var last = 0
            forEachVariable(t) { range, name in
                out += ns.substring(with: NSRange(location: last, length: range.location - last))
                out += sample[name] ?? ns.substring(with: range)
                last = range.location + range.length
            }
            out += ns.substring(from: last)
            return folders ? out : out.replacingOccurrences(of: "/", with: "_")
        }
        let blank = { (s: String) in s.trimmingCharacters(in: .whitespaces).isEmpty }
        let file = fill(blank(fileTemplate) ? defaultFileName : fileTemplate, folders: false)
        let folder = blank(folderTemplate) ? "" : fill(folderTemplate, folders: true)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
        return "\(folder)\(file).\(ext)"
    }
}

public enum Format {
    public static func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = value
        var i = 0
        while v >= 1024, i < units.count - 1 {
            v /= 1024
            i += 1
        }
        return i == 0 ? String(format: "%.0f %@", v, units[i]) : String(format: "%.1f %@", v, units[i])
    }

    public static func duration(_ seconds: Double) -> String {
        let t = Int(max(0, seconds))
        let (h, m, s) = (t / 3600, t / 60 % 60, t % 60)
        return h >= 1 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "20240131" → "2024-01-31".
    public static func date(_ yyyymmdd: String?) -> String? {
        guard let d = yyyymmdd, d.count == 8 else { return nil }
        return "\(d.prefix(4))-\(d.dropFirst(4).prefix(2))-\(d.suffix(2))"
    }

    /// "1080p60 (Full HD)".
    public static func height(_ h: Int, fps: Int = 0) -> String {
        let name = fps >= 50 ? "\(h)p\(fps)" : "\(h)p"
        let tag: String? = switch h {
        case 4320...: "8K"
        case 2160...: "4K"
        case 1440...: "2K"
        case 1080...: L.get("Quality_FullHD")
        case 720...: L.get("Quality_HD")
        default: nil
        }
        return tag.map { "\(name) (\($0))" } ?? name
    }

    /// Quality label with an approximate size: "1080p (Full HD) · ~120 MB".
    public static func quality(_ q: QualityOption) -> String {
        if let b = q.estimatedBytes, b > 0 {
            return "\(height(q.height, fps: q.fps)) · \(L.format("Size_Approx", bytes(Double(b))))"
        }
        return height(q.height, fps: q.fps)
    }
}

/// Display text for download rows, built from the stored request so it follows the current language.
public enum DownloadLabels {
    /// "YouTube · MP4 · 1080p · P3".
    public static func label(_ r: DownloadRequest, partIndex: Int?) -> String {
        let label = "\(UrlTools.detectPlatform(r.url).displayName) · \(optionsLabel(r))"
        return partIndex.map { "\(label) · P\($0)" } ?? label
    }

    /// "MP4 · 1080p · H.264", without the platform.
    public static func optionsLabel(_ r: DownloadRequest) -> String {
        if r.isCover { return L.get("Mode_Cover") }
        if r.isAudio { return audioOutputLabel(r.audioOutputFormat) }
        let container = (r.needsMkv ? "mkv" : r.container.isEmpty ? "mp4" : r.container).uppercased()
        var mode = r.maxHeight > 0 ? "\(container) · \(r.maxHeight)p" : "\(container) · \(L.get("Quality_Best"))"
        let codec = VideoCodecs.shortName(r.codec)
        if !codec.isEmpty { mode += " · \(codec)" }
        if let picture = pictureLabel(r.dynamicRange) { mode += " · \(picture)" }
        if let sound = soundLabel(r.audioFormat) { mode += " · \(sound)" }
        return mode
    }

    /// One-line description of a template: "MP4 · 1080p · H.264 · AAC · Subtitles".
    public static func summary(_ t: DownloadTemplate) -> String {
        var parts: [String] = []
        if t.mode == "cover" {
            parts.append(L.get("Mode_Cover"))
        } else if t.mode == "audio" {
            parts.append(audioOutputLabel(t.audioFormat == "auto" ? "mp3" : t.audioFormat))
            if t.audioQuality > 0, !["flac", "wav", MediaFeatures.original].contains(t.audioFormat) {
                parts.append("\(t.audioQuality) kbps")
            }
        } else {
            parts.append(t.container.uppercased())
            parts.append(t.maxHeight > 0 ? "\(t.maxHeight)p" : L.get("Quality_Best"))
            let codec = VideoCodecs.shortName(t.codec)
            if !codec.isEmpty { parts.append(codec) }
            if let picture = pictureLabel(t.dynamicRange) { parts.append(picture) }
            if t.audioFormat == "aac" { parts.append("AAC") }
            if t.audioFormat == "opus" { parts.append("Opus") }
            if let sound = soundLabel(t.audioFormat) { parts.append(sound) }
            if t.audioQuality > 0 { parts.append("\(t.audioQuality) kbps") }
        }
        if !t.audioLanguage.isEmpty { parts.append(t.audioLanguage) }
        if t.subtitles, t.mode != "cover" { parts.append(L.get("Options_Subtitles")) }
        if !t.folderTemplate.isEmpty { parts.append(t.folderTemplate) }
        return parts.joined(separator: " · ")
    }

    /// "MP3 audio", or "Original audio" when the source format is kept.
    private static func audioOutputLabel(_ format: String) -> String {
        format == MediaFeatures.original ? L.get("Label_AudioOriginal") : L.format("Label_Audio", format.uppercased())
    }

    /// Only the non-default picture choices are worth a word in a summary.
    private static func pictureLabel(_ picture: String) -> String? {
        switch picture {
        case MediaFeatures.dolbyVision: MediaFeatures.label("DV")
        case MediaFeatures.sdr: "SDR"
        default: nil
        }
    }

    private static func soundLabel(_ audioFormat: String) -> String? {
        audioFormat == MediaFeatures.hiRes || audioFormat == MediaFeatures.atmos ? MediaFeatures.label(audioFormat) : nil
    }

    /// Status text for states that don't carry live progress; nil for states whose text is specific (failures keep
    /// their error message).
    public static func restingStatus(_ r: DownloadRecord) -> String? {
        switch r.state {
        case .completed:
            r.filePath.map { L.format("Status_CompletedFile", ($0 as NSString).lastPathComponent) } ?? L.get("Status_Completed")
        case .canceled: L.get("Status_Canceled")
        case .paused: L.get("Status_Paused")
        case .queued: L.get("Status_Resuming")
        default: nil
        }
    }
}

/// The status groups the download list can be narrowed to.
public enum DownloadStatusFilter: String, CaseIterable, Sendable, Hashable {
    case all = "All", active = "Active", completed = "Completed", failed = "Failed"
}

/// What the download list shows: a status group, one platform, and text found in the title or link.
public struct DownloadFilter: Equatable, Sendable {
    public var status: DownloadStatusFilter = .all
    public var platform: Platform?
    public var query = ""

    public init(status: DownloadStatusFilter = .all, platform: Platform? = nil, query: String = "") {
        self.status = status
        self.platform = platform
        self.query = query
    }

    /// Paused counts as in progress (it continues later); canceled sits with failed (neither finished).
    public static func group(of state: DownloadState) -> DownloadStatusFilter {
        switch state {
        case .completed: .completed
        case .failed, .canceled: .failed
        default: .active
        }
    }

    /// Platform and text only, ignoring the status: what the counts on the status choices are taken over.
    public func matchesExceptStatus(_ r: DownloadRecord) -> Bool {
        if let platform, UrlTools.detectPlatform(r.request.url) != platform { return false }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty || r.title.localizedCaseInsensitiveContains(q) || r.request.url.containsIgnoringCase(q)
    }

    /// The same, from the few fields the list keeps at hand: it runs for every row whenever a row changes state.
    public func matches(state: DownloadState, title: String, url: String, platform rowPlatform: Platform) -> Bool {
        if status != .all, Self.group(of: state) != status { return false }
        if let platform, rowPlatform != platform { return false }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty || title.localizedCaseInsensitiveContains(q) || url.containsIgnoringCase(q)
    }

    public func matches(_ r: DownloadRecord) -> Bool {
        (status == .all || Self.group(of: r.state) == status) && matchesExceptStatus(r)
    }
}

/// Turns raw yt-dlp stderr into a short, actionable message.
public enum ErrorMapper {
    /// The last "ERROR:" line, or the last line if there is none.
    public static func lastErrorLine(_ raw: String) -> String {
        let lines = raw.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let i = lines.lastIndex(where: { $0.hasPrefix("ERROR:") }) else { return lines.last ?? "" }
        // Download errors come as "ERROR: \r[download] Got error: …", which the line reader splits in two.
        return lines[i] == "ERROR:" && i + 1 < lines.count ? "ERROR: \(lines[i + 1])" : lines[i]
    }

    public static func friendly(_ raw: String) -> String {
        let line = lastErrorLine(raw)
        if line.isEmpty { return L.get("Error_UnexpectedExit") }
        func has(_ part: String) -> Bool { line.containsIgnoringCase(part) }
        let hint: String? =
            if has("Sign in to confirm") { L.get("Error_BotCheck") }
            else if has("Unsupported URL") { L.get("Error_Unsupported") }
            else if has("HTTP Error 429") || has("Too Many Requests") { L.get("Error_RateLimited") }
            else if isCookieReadError(line) { L.get("Error_Cookies") }
            else if has("Private video") || has("members-only") || has("Join this channel") { L.get("Error_Private") }
            else if isNoFormats(line) { L.get("Error_NoFormats") }
            // Only the real "video is gone" messages; "Requested format is not available" is handled above.
            else if has("Video unavailable") || has("video is unavailable") || has("This video is not available")
                || has("啥都木有") || has("has been removed") { L.get("Error_Unavailable") }
            else if has("ffmpeg"), has("not found") || has("not installed") { L.get("Error_NoFfmpeg") }
            else if has("No space left") || has("Errno 28") { L.get("Error_DiskFull") }
            else if has("timed out") || has("Unable to download") || has("getaddrinfo") || has("nodename nor servname")
                || has("Connection reset") || has("SSL") { L.get("Error_Network") }
            else { nil }
        return hint.map { "\($0)\n\(line)" } ?? line
    }

    /// yt-dlp could not read the configured browser's cookie store (locked / encrypted / missing).
    public static func isCookieReadError(_ error: String) -> Bool {
        error.containsIgnoringCase("cookie database") || error.containsIgnoringCase("Failed to decrypt")
            || error.containsIgnoringCase("cookies from browser")
            || (error.containsIgnoringCase("could not find") && error.containsIgnoringCase("cookies"))
    }

    /// The external downloader failed ("ERROR: aria2c exited with code 1"), not the site.
    public static func isAria2Failure(_ error: String) -> Bool { error.containsIgnoringCase("aria2c exited with code") }

    /// The site answered but offered nothing downloadable (on YouTube typically a sign-in / cookie problem).
    public static func isNoFormats(_ error: String) -> Bool {
        error.containsIgnoringCase("Requested format is not available") || error.containsIgnoringCase("No video formats found")
    }

    /// YouTube refuses without a signed-in account (age-restricted, members-only, private, bot check).
    public static func needsSignIn(_ error: String) -> Bool {
        ["Sign in to confirm", "age-restricted", "inappropriate for some users", "members-only", "Join this channel",
         "available to this channel's members", "Private video", "use --cookies"].contains { error.containsIgnoringCase($0) }
    }
}
