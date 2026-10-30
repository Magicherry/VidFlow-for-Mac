import Foundation

/// A yt-dlp failure: `message` is user-facing, `detail` is the raw output.
public struct YtDlpError: LocalizedError, Sendable {
    public var message: String
    public var detail: String?
    public init(_ message: String, detail: String? = nil) {
        self.message = message
        self.detail = detail
    }
    public var errorDescription: String? { message }
}

/// Builds yt-dlp command lines. Pure: everything it depends on is passed in, so it is unit tested.
public enum YtDlpArgs {
    public static let progressTemplate =
        "download:VFP|%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s"
        + "|%(progress.fragment_index)s|%(progress.fragment_count)s"

    /// Printed before downloading: format, size of each stream (NA when unknown), thumbnail, title.
    public static let startTemplate =
        "before_dl:VFS|%(format_id)s"
        + "|%(requested_formats.0.filesize,requested_formats.0.filesize_approx,filesize,filesize_approx|NA)s"
        + ",%(requested_formats.1.filesize,requested_formats.1.filesize_approx|NA)s"
        + "|%(thumbnail)s|%(title)s"

    /// Where cookies and tools come from.
    public struct Environment: Sendable, Equatable {
        public var ffmpegDir: String?
        public var loginCookieFile: String?
        public var skipBrowserCookies = false
        public var skipLoginCookies = false
        public var denoPath: String?
        public var aria2Path: String?
        public var systemProxy: String?

        public init(ffmpegDir: String? = nil, loginCookieFile: String? = nil, skipBrowserCookies: Bool = false,
                    skipLoginCookies: Bool = false, denoPath: String? = nil, aria2Path: String? = nil, systemProxy: String? = nil) {
            self.ffmpegDir = ffmpegDir
            self.loginCookieFile = loginCookieFile
            self.skipBrowserCookies = skipBrowserCookies
            self.skipLoginCookies = skipLoginCookies
            self.denoPath = denoPath
            self.aria2Path = aria2Path
            self.systemProxy = systemProxy
        }
    }

    /// 16 connections per file, fragments of at least 1 MB. aria2's own console output is reduced to one summary line
    /// a second, which `YtDlpOutputParser` reads as progress (yt-dlp prints none meanwhile).
    static let aria2Args =
        "aria2c:-x16 -s16 -k1M --summary-interval=1 --show-console-readout=false --console-log-level=warn --file-allocation=none"

    public static func info(url: String, settings s: AppSettings, env: Environment) -> [String] {
        // --flat-playlist: list playlist / multi-part entries without resolving each one (fast).
        var args = ["-J", "--no-warnings", "--flat-playlist"]
        if UrlTools.isYouTubeVideoInPlaylist(url) { args.append("--no-playlist") }
        args += common(s, env)
        args.append(url)
        return args
    }

    /// A media file VidFlow located itself (Douyin): yt-dlp only downloads it, so the names it would normally read
    /// from the page are passed in `known`.
    public struct DirectMedia: Sendable {
        public var url: String
        public var referer: String
        public var known: [String: String?]
        public init(url: String, referer: String, known: [String: String?]) {
            self.url = url
            self.referer = referer
            self.known = known
        }
    }

    public static func download(_ req: DownloadRequest, settings s: AppSettings, env: Environment, direct: DirectMedia? = nil) -> [String] {
        let hasFfmpeg = env.ffmpegDir != nil
        let platform = UrlTools.detectPlatform(req.url)
        var args = [
            "--no-playlist", "--newline", "--progress", "--no-warnings", "--continue",
            "-P", req.outputFolder,
            "-o", NamingTemplate.toOutputTemplate(fileTemplate: req.fileNameTemplate, folderTemplate: req.folderTemplate,
                                                  platformName: platform.displayName, known: direct?.known),
            "--print", startTemplate,
            "--print", "before_dl:VFN|%(filename)s",
            "--print", "after_move:VFF|%(filepath)s",
            "--progress-template", progressTemplate,
        ]
        if req.overwrite { args.append("--force-overwrites") }

        if let direct {
            // One ready-made MP4 with picture and sound: nothing to choose or merge.
            args += ["--add-header", "Referer:\(direct.referer)"]
            if req.isCover {
            } else if req.isAudio {
                let fmt = req.audioOutputFormat
                args += ["-x", "--audio-format", fmt, "--audio-quality",
                         fmt == "flac" || fmt == "wav" || req.audioQuality <= 0 ? "0" : "\(req.audioQuality)K"]
            } else if req.container != "mp4", hasFfmpeg {
                args += [req.recode ? "--recode-video" : "--remux-video", req.container]
            }
            if s.speedLimitKBps > 0 { args += ["-r", "\(s.speedLimitKBps)K"] }
            args += connections(s, env)
            args += common(s, env)
            args.append(direct.url)
            return args
        }

        if req.isCover {
            // Just the thumbnail: yt-dlp picks the largest; WebP (YouTube's) becomes JPG, which everything opens.
            args += ["--skip-download", "--write-thumbnail"]
            if hasFfmpeg { args += ["--convert-thumbnails", "jpg"] }
            // Nothing is downloaded, so "after_move" never comes: report the image (after conversion) instead.
            args += ["--print", "after_video:VFF|%(thumbnails.-1.filepath)s"]
            args += common(s, env)
            args.append(req.url)
            return args
        }

        let lang = languageFilter(req.audioLanguage)
        let splitAudio = splitDownloaders(platform, env)
        if !req.isAudio {
            let video = videoFilter(req)
            let audio = audioFilter(req)
            if hasFfmpeg {
                // Dolby Vision and Hi-Res FLAC only fit MKV: say so up front rather than let MP4 fail over to it.
                let merge = req.needsMkv ? "mkv" : FormatCompatibility.mergeFormats(req.container)
                let chain = formatChain(video: video, audio: audio, lang: lang)
                args += ["-f", splitAudio ? dashAudioFirst(chain) : chain, "--merge-output-format", merge]
                // Re-encode when the streams don't fit the chosen container (only if needed; slow). Never for Dolby
                // Vision / Hi-Res: re-encoding would throw away exactly what was asked for.
                if req.recode, !req.needsMkv { args += ["--recode-video", req.container] }
            } else {
                // Without ffmpeg separate streams cannot be merged; take the best single file.
                args += ["-f", unique(["b\(notImage)\(video)", "b\(notImage)", "b"]).joined(separator: "/")]
            }
            // Resolution (yt-dlp's "res" is the shorter side, so portrait 1080×1920 counts as 1080p), then frame rate,
            // then bitrate. yt-dlp's default ranks codecs (AV1 > VP9 > HEVC > H.264) ahead of bitrate, which picks the
            // smallest stream: e.g. Bilibili 1080p AV1 at ~600 kbps over H.264 at ~2600 kbps. Total bitrate, not video
            // bitrate: some sites' best file is one MP4 with sound and no separate video bitrate (X's 10 Mbps 1080p
            // would otherwise lose to a 2.8 Mbps HLS stream).
            var sort = [req.maxHeight > 0 ? "res:\(req.maxHeight)" : "res"]
            // The global compatibility mode only steers "auto"; an explicit codec choice wins.
            let compatibility = s.preferH264 && req.codec == VideoCodecs.auto
            // Then the picture asked for (HDR / Dolby Vision / SDR) at that resolution, ahead of bitrate: a Dolby
            // Vision stream can have a slightly lower bitrate than the SDR one and would otherwise lose.
            sort.append(MediaFeatures.hdrSort(req.dynamicRange, compatibilityMode: compatibility))
            if compatibility { sort += ["vcodec:h264", "acodec:m4a"] }
            sort += ["fps", "tbr"]
            if req.audioQuality > 0 { sort.append("abr:\(req.audioQuality)") }
            args += ["-S", sort.joined(separator: ",")]
        } else {
            let fmt = req.audioOutputFormat
            // "best" (original) keeps the source as it is; YtDlpService turns it into the source's own format first.
            args += ["-f", splitAudio ? dashAudioFirst(audioChain(req)) : audioChain(req), "-x", "--audio-format", fmt,
                     "--audio-quality",
                     fmt == "flac" || fmt == "wav" || fmt == MediaFeatures.original || req.audioQuality <= 0 ? "0" : "\(req.audioQuality)K"]
        }

        if req.writeSubtitles {
            let setting = s.subtitleLanguages.trimmingCharacters(in: .whitespacesAndNewlines)
            var langs = setting.isEmpty ? SubtitleLanguageSet.fallback : setting
            if platform == .bilibili, s.saveDanmaku { langs += ",danmaku" }
            args += ["--write-subs", "--sub-langs", langs]
            // Bilibili already serves SRT, and its danmaku is XML that must not be converted.
            if platform != .bilibili, hasFfmpeg { args += ["--convert-subs", "srt"] }
        }

        if s.embedMetadata, hasFfmpeg { args += ["--embed-metadata", "--embed-thumbnail"] }
        args += chapters(s, platform, hasFfmpeg)

        if s.speedLimitKBps > 0 { args += ["-r", "\(s.speedLimitKBps)K"] }

        args += connections(s, env)
        // Each stream also offered as "dash" (the same file in ranged chunks), which dashAudioFirst picks for audio.
        if splitAudio { args += ["--extractor-args", "youtube:formats=duplicate"] }
        args += common(s, env)
        args.append(req.url)
        return args
    }

    /// Chapters and SponsorBlock. --embed-metadata embeds chapters too, so turning them off needs saying.
    /// SponsorBlock only knows YouTube; marked segments show up as chapters, so marking embeds chapters regardless.
    private static func chapters(_ s: AppSettings, _ platform: Platform, _ hasFfmpeg: Bool) -> [String] {
        guard hasFfmpeg else { return [] }
        let sponsorBlock = platform == .youTube ? s.sponsorBlock : SponsorBlockModes.off
        var args = [s.embedChapters || sponsorBlock == SponsorBlockModes.mark ? "--embed-chapters" : "--no-embed-chapters"]
        if sponsorBlock == SponsorBlockModes.mark {
            args += ["--sponsorblock-mark", "all"]
        } else if sponsorBlock == SponsorBlockModes.remove {
            args += ["--sponsorblock-remove", SponsorBlockModes.removedCategories]
        }
        return args
    }

    /// Several connections per download. YouTube (and many proxies) hold each connection to well under 1 MB/s, so one
    /// connection is what makes a download slow. Whole files go through aria2c; streams made of fragments (HLS / DASH)
    /// stay with yt-dlp, which fetches 8 fragments at a time.
    private static func connections(_ s: AppSettings, _ env: Environment) -> [String] {
        // yt-dlp's -r applies to each connection, so eight of them would download at eight times the limit.
        if s.speedLimitKBps > 0 { return ["-N", "1"] }
        var args = ["-N", "8"]
        guard let aria2 = env.aria2Path else { return args }
        args += ["--downloader", aria2, "--downloader", "m3u8:native", "--downloader", "dash:native",
                 "--downloader-args", aria2Args]
        // yt-dlp itself follows the system's proxy setting, aria2c does not: hand it over explicitly.
        if s.proxy.trimmingCharacters(in: .whitespaces).isEmpty, let proxy = env.systemProxy { args += ["--proxy", proxy] }
        return args
    }

    /// YouTube with aria2: video through aria2c, audio through yt-dlp itself. YouTube serves a request that names its
    /// byte range in the URL (yt-dlp's way) fast at first, then slows it to a crawl; aria2c's ranged requests are slow
    /// from the start, and only many of them at once make up for it. A video stream is large enough for that; an audio
    /// stream (a few MB) would take 10 s to minutes through aria2c instead of about 1 s.
    private static func splitDownloaders(_ platform: Platform, _ env: Environment) -> Bool {
        platform == .youTube && env.aria2Path != nil
    }

    /// Tries each audio choice as a "dash" stream first (downloaded by yt-dlp), then as it is.
    static func dashAudioFirst(_ chain: String) -> String {
        chain.split(separator: "/").flatMap { part -> [String] in
            let f = String(part)
            return f.contains("+ba") || f.hasPrefix("ba") ? [f + dashOnly, f] : [f]
        }.joined(separator: "/")
    }

    private static let dashOnly = "[protocol=http_dash_segments]"

    /// Video stream filter: the chosen codec, or for WebM (which only holds VP9 / AV1) those codecs.
    private static func videoFilter(_ r: DownloadRequest) -> String {
        let codec = VideoCodecs.filter(r.codec)
        if !codec.isEmpty { return codec }
        return r.container == "webm" ? "[vcodec~='^(vp0?9|av01)']" : ""
    }

    /// Audio stream filter for video downloads. MP4 prefers AAC (Opus in MP4 trips up many players and editors), WebM
    /// needs Opus / Vorbis, MKV takes the best of anything (Hi-Res FLAC when offered). By codec, not extension:
    /// Bilibili labels its FLAC and Dolby tracks ".m4a" too.
    private static func audioFilter(_ r: DownloadRequest) -> String {
        switch r.audioFormat {
        case "aac": return "[acodec^=mp4a]"
        case "opus": return "[acodec=opus]"
        case MediaFeatures.hiRes: return "[acodec~='^(flac|alac)']"
        case MediaFeatures.atmos: return "[acodec~='^(ec-?3|eac3|ac-?4)']"
        default:
            switch r.container {
            case "webm": return "[acodec~='^(opus|vorbis)']"
            case "mkv": return ""
            default: return "[acodec^=mp4a]"
            }
        }
    }

    /// Audio-only downloads: the track in the wanted format and language, relaxing to the best one.
    private static func audioChain(_ req: DownloadRequest) -> String {
        let lang = languageFilter(req.audioLanguage)
        let preferred = switch req.audioOutputFormat {
        case "m4a": "[acodec^=mp4a]"
        case "opus": "[acodec=opus]"
        default: ""
        }
        var chain: [String] = []
        if !lang.isEmpty { chain.append("ba\(preferred)\(lang)") }
        if !preferred.isEmpty { chain.append("ba\(preferred)") }
        if !lang.isEmpty { chain.append("ba\(lang)") }
        chain += ["ba", "b"]
        return unique(chain).joined(separator: "/")
    }

    /// Asks (without downloading) which audio track an audio-only download would take, printing its codec. yt-dlp's
    /// own "best" output keeps the source container, which leaves Bilibili's Hi-Res FLAC inside an .m4a.
    public static func probeAudio(_ req: DownloadRequest, settings s: AppSettings, env: Environment) -> [String] {
        var args = ["-s", "--no-playlist", "--no-warnings", "--print", "%(acodec)s", "-f", audioChain(req)]
        args += common(s, env)
        args.append(req.url)
        return args
    }

    private static func languageFilter(_ language: String) -> String {
        let l = language.trimmingCharacters(in: .whitespacesAndNewlines)
        return l.isEmpty ? "" : "[language^=\(l)]"
    }

    /// Most specific first, then relax: language, then audio codec, then video codec, so a choice the site can't
    /// satisfy degrades to the best available instead of failing.
    static func formatChain(video: String, audio: String, lang: String) -> String {
        unique([
            "bv*\(notImage)\(video)+ba\(audio)\(lang)",
            "bv*\(notImage)\(video)+ba\(lang)",
            "bv*\(notImage)\(video)+ba\(audio)",
            "bv*\(notImage)\(video)+ba",
            "bv*\(notImage)+ba\(audio)",
            "bv*\(notImage)+ba",
            "b\(notImage)",
            "b",
        ]).joined(separator: "/")
    }

    /// Some sites list preview images among the formats (Weibo's 180×320 "scrubber" JPEG). Their codec is "unknown"
    /// rather than "none", so bv* would take them when a low resolution is asked for.
    static let notImage = "[ext!=jpg][ext!=png][ext!=webp]"

    public static func common(_ s: AppSettings, _ env: Environment) -> [String] {
        var args = ["--no-colors", "--encoding", "utf-8"]
        if let ffmpeg = env.ffmpegDir { args += ["--ffmpeg-location", ffmpeg] }
        // YouTube needs a JavaScript runtime to solve its player challenges; without one yt-dlp warns that "some
        // formats may be missing" (often the higher-quality ones).
        if let deno = env.denoPath { args += ["--js-runtimes", "deno:\(deno)"] }
        let proxy = s.proxy.trimmingCharacters(in: .whitespaces)
        if !proxy.isEmpty { args += ["--proxy", proxy] }

        // Cookie source priority: explicit cookies.txt > browser > in-app login.
        if !s.cookiesFile.isEmpty, FileManager.default.fileExists(atPath: s.cookiesFile) {
            args += ["--cookies", s.cookiesFile]
        } else if !s.cookiesBrowser.isEmpty, !env.skipBrowserCookies {
            args += ["--cookies-from-browser", s.cookiesBrowser]
        } else if let login = env.loginCookieFile, !env.skipLoginCookies {
            args += ["--cookies", login]
        }
        return args
    }

    public static func usesBrowserCookies(_ s: AppSettings) -> Bool {
        !s.cookiesBrowser.isEmpty && !(!s.cookiesFile.isEmpty && FileManager.default.fileExists(atPath: s.cookiesFile))
    }

    private static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }
}

/// Progress reported while yt-dlp runs. `processing` means all streams are downloaded and ffmpeg is merging /
/// converting; `streamFinished` marks one stream done with more to come. `percent` covers the whole download (all
/// streams); the byte counts are the current stream's.
public struct DownloadProgress: Equatable, Sendable {
    public var processing: Bool
    public var streamFinished: Bool
    public var part: Int
    public var parts: Int
    public var percent: Double
    public var downloaded: Int64
    public var total: Int64
    public var speed: Double
    public var eta: Double
}

public enum DownloadEvent: Equatable, Sendable {
    case started(parts: Int, title: String?, thumbnailURL: String?)
    case file(String)
    /// The path the download will end up at, before it starts.
    case expectedFile(String)
    case progress(DownloadProgress)
}

/// Parses the machine-readable lines VidFlow asks yt-dlp to print (see `YtDlpArgs`): `VFS|format|sizes|thumbnail|title`
/// before downloading, `VFP|…` for progress, `VFF|path` at the end. Stateful: counts finished streams so "video then
/// audio" can be told apart, and turns them into one smooth percentage for the whole download.
public final class YtDlpOutputParser {
    /// When a stream's size is unknown until it starts: audio is typically about a tenth of the video.
    private static let unknownLastStreamShare = 0.1

    private var parts = 1
    private var finished = 0
    private var sizes: [Int64] = [0]
    private var estimated = [false]
    private var percent = 0.0

    public init() {}

    public func feed(_ input: String) -> DownloadEvent? {
        var line = input
        if line.hasPrefix("VFS|") {
            // The title comes last and may itself contain "|".
            let f = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            parts = (f.count > 1 ? f[1].filter { $0 == "+" }.count : 0) + 1
            finished = 0
            percent = 0
            sizes = Array(repeating: 0, count: parts)
            estimated = Array(repeating: false, count: parts)
            let printed = (f.count > 2 ? f[2] : "").split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            for i in 0..<parts where i < printed.count { sizes[i] = Self.long(printed[i]) }
            return .started(parts: parts, title: Self.nullIfNA(f.count > 4 ? f[4] : nil), thumbnailURL: Self.nullIfNA(f.count > 3 ? f[3] : nil))
        }
        // aria2c writes its own readout without a line break, so yt-dlp's final line can end up glued after it.
        if let glued = line.range(of: "]VF"), glued.lowerBound > line.startIndex {
            line = String(line[line.index(after: glued.lowerBound)...])
        }
        if line.hasPrefix("VFN|") { return .expectedFile(String(line.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)) }
        if line.hasPrefix("VFF|") { return .file(String(line.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)) }
        if line.hasPrefix("[#") { return aria2(line) }
        guard line.hasPrefix("VFP|") else { return nil }

        let p = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard p.count >= 7 else { return nil }
        if p[1] == "finished" {
            _ = updateSizes(total: Self.long(p[3]), estimate: Self.long(p[4]))
            finished += 1
            let last = finished >= parts
            percent = last ? 100 : max(percent, overall(done: finished, fraction: 0))
            return .progress(DownloadProgress(processing: last, streamFinished: !last, part: min(finished, parts), parts: parts,
                                              percent: percent, downloaded: 0, total: 0, speed: 0, eta: 0))
        }
        return downloading(Self.long(p[2]), total: Self.long(p[3]), estimate: Self.long(p[4]), speed: Self.dbl(p[5]), eta: Self.dbl(p[6]),
                           fragment: p.count >= 9 ? Self.long(p[7]) : 0, fragments: p.count >= 9 ? Self.long(p[8]) : 0)
    }

    /// aria2c's summary line, e.g. `[#86c7bd 82MiB/83MiB(99%) CN:16 DL:33MiB ETA:1s]`. While aria2c downloads, yt-dlp
    /// prints no progress of its own; it reports the stream finished as usual afterwards.
    private func aria2(_ line: String) -> DownloadEvent? {
        guard let g = RX.firstGroups(Self.aria2Readout, in: line), let done = g[1], let totalText = g[2] else { return nil }
        let total = Self.bytes(totalText)
        guard total > 0 else { return nil }
        return downloading(Self.bytes(done), total: total, estimate: 0, speed: g[3].map { Double(Self.bytes($0)) } ?? 0,
                           eta: g[4].map(Self.seconds) ?? 0, fragment: 0, fragments: 0)
    }

    private static let aria2Readout = RX.make(#"^\[#\w+ ([\d.]+\w*)/([\d.]+\w*)\(\d+%\)(?: CN:\d+)?(?: DL:([\d.]+\w*))?(?: ETA:(\w+))?\]"#)

    /// Records the current stream's size: an exact size beats the one printed up front; a running estimate only stands
    /// in for an unknown one. Returns the size to measure progress against.
    private func updateSizes(total: Int64, estimate: Int64) -> Int64 {
        let current = min(finished, parts - 1)
        if total > 0 {
            sizes[current] = total
            estimated[current] = false
            return total
        }
        if estimate > 0, sizes[current] <= 0 || estimated[current] {
            sizes[current] = estimate
            estimated[current] = true
            return estimate
        }
        return 0
    }

    private func downloading(_ downloaded: Int64, total inTotal: Int64, estimate: Int64, speed: Double, eta: Double,
                             fragment: Int64, fragments: Int64) -> DownloadEvent {
        let current = min(finished, parts - 1)
        let total = updateSizes(total: inTotal, estimate: estimate)
        // Fragmented streams (HLS / DASH segments) re-estimate their total after every fragment, which makes
        // bytes ÷ estimate jump around; the fragment count only goes up.
        let fraction = fragments > 0 ? Double(fragment) / Double(fragments) : total > 0 ? Double(downloaded) / Double(total) : 0
        // Never move backwards within one download.
        percent = max(percent, overall(done: current, fraction: min(max(fraction, 0), 1)))
        return .progress(DownloadProgress(processing: false, streamFinished: false, part: current + 1, parts: parts,
                                          percent: percent, downloaded: downloaded, total: total, speed: speed, eta: eta))
    }

    /// Percent of the whole download with `done` streams finished and the next one `fraction` through, each stream
    /// weighted by its size.
    private func overall(done: Int, fraction: Double) -> Double {
        let known = sizes.filter { $0 > 0 }.map(Double.init)
        let knownSum = known.reduce(0, +)
        let weights: [Double] = (0..<parts).map { i in
            if sizes[i] > 0 { return Double(sizes[i]) }
            if known.isEmpty { return 1 }
            return i == parts - 1 && parts > 1 ? knownSum * Self.unknownLastStreamShare : knownSum / Double(known.count)
        }
        let sum = weights.reduce(0, +)
        let reached = weights.prefix(done).reduce(0, +) + (done < parts ? weights[done] * fraction : 0)
        return min(max(reached / sum * 100, 0), 100)
    }

    private static func nullIfNA(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty, s != "NA" else { return nil }
        return s
    }

    private static func long(_ s: String) -> Int64 {
        guard let v = Double(s), v.isFinite, abs(v) < 9e18 else { return 0 }
        return Int64(v)
    }

    private static func dbl(_ s: String) -> Double {
        guard let v = Double(s), v.isFinite else { return 0 }
        return v
    }

    /// aria2's sizes: "82MiB", "512KiB", "0B", "1.2GiB".
    static func bytes(_ s: String) -> Int64 {
        let digits = s.prefix { $0.isNumber || $0 == "." }
        guard let v = Double(digits) else { return 0 }
        let scale: Int64 = switch s.dropFirst(digits.count) {
        case "KiB": 1 << 10
        case "MiB": 1 << 20
        case "GiB": 1 << 30
        case "TiB": 1 << 40
        default: 1
        }
        return Int64(v * Double(scale))
    }

    /// aria2's ETA: "45s", "3m12s", "1h2m".
    static func seconds(_ s: String) -> Double {
        var total = 0.0
        var n = 0.0
        for c in s {
            if let d = c.wholeNumberValue {
                n = n * 10 + Double(d)
                continue
            }
            total += n * (c == "h" ? 3600 : c == "m" ? 60 : 1)
            n = 0
        }
        return total
    }
}

/// Turns yt-dlp's `-J` JSON into `VideoInfo` or `PlaylistInfo`.
public enum InfoParser {
    public static func parse(_ json: String, requestedURL: String) throws -> MediaInfo {
        guard let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw YtDlpError(L.get("Error_UnexpectedExit"))
        }
        let url = str(root, "webpage_url") ?? requestedURL
        let detected = UrlTools.detectPlatform(url)
        let platform = detected != .other ? detected : UrlTools.detectPlatform(requestedURL)

        if let type = str(root, "_type"), type == "playlist" || type == "multi_video" {
            var entries: [PlaylistEntry] = []
            for e in root["entries"] as? [Any] ?? [] {
                guard let e = e as? [String: Any] else { continue } // deleted / private entries come back as null
                guard var entryURL = str(e, "webpage_url") ?? str(e, "url") else { continue }
                if !entryURL.lowercased().hasPrefix("http"), platform == .youTube {
                    entryURL = "https://www.youtube.com/watch?v=\(entryURL)"
                }
                let index = entries.count + 1
                entries.append(PlaylistEntry(index: index, url: entryURL,
                                             title: str(e, "title") ?? L.format("Playlist_EntryFallback", index),
                                             duration: num(e, "duration"), thumbnailURL: pickThumbnail(e)))
            }
            var info = PlaylistInfo(url: url, title: str(root, "title") ?? L.get("Untitled"))
            info.uploader = str(root, "uploader") ?? str(root, "channel")
            info.thumbnailURL = pickThumbnail(root) ?? entries.first { $0.thumbnailURL != nil }?.thumbnailURL
            info.platform = platform
            info.entries = entries
            return .playlist(info)
        }

        var info = VideoInfo(url: url, title: str(root, "title") ?? L.get("Untitled"))
        info.duration = num(root, "duration")
        let q = qualities(root, duration: info.duration)
        info.qualities = q.list
        info.audioBytes = q.audio
        info.codecs = q.codecs
        info.audioLanguages = audioLanguages(root)
        let f = features(root)
        info.hdrKinds = f.kinds
        info.hasHiRes = f.hiRes
        info.hasAtmos = f.atmos
        info.uploader = str(root, "uploader") ?? str(root, "channel")
        info.thumbnailURL = pickThumbnail(root)
        info.uploadDate = str(root, "upload_date")
        info.platform = platform
        return .video(info)
    }

    private static func formats(_ root: [String: Any]) -> [[String: Any]] {
        (root["formats"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }

    /// HDR kinds among the video streams (in yt-dlp's preference order: DV first), and whether a Hi-Res lossless or
    /// Dolby Atmos audio stream is offered.
    private static func features(_ root: [String: Any]) -> (kinds: [String], hiRes: Bool, atmos: Bool) {
        var kinds = Set<String>()
        var hiRes = false
        var atmos = false
        for f in formats(root) {
            if let vcodec = str(f, "vcodec"), vcodec != "none", let kind = MediaFeatures.hdrKind(str(f, "dynamic_range")) {
                kinds.insert(kind)
            }
            let acodec = str(f, "acodec")
            hiRes = hiRes || MediaFeatures.isHiResCodec(acodec)
            atmos = atmos || MediaFeatures.isAtmosCodec(acodec)
        }
        let order = ["DV", "HDR12", "HDR10+", "HDR10", "HLG"]
        let rank = { (k: String) in order.firstIndex(of: k) ?? order.count }
        return (kinds.sorted { (rank($0), $0) < (rank($1), $1) }, hiRes, atmos)
    }

    /// One option per resolution (shorter side, highest first), with the best fps seen and an approximate size
    /// (largest video stream at that height + the best audio stream).
    private static func qualities(_ root: [String: Any], duration: Double?) -> (list: [QualityOption], audio: Int64?, codecs: [String: Int]) {
        var byHeight: [Int: (fps: Int, bytes: Int64?)] = [:]
        var codecs: [String: Int] = [:]
        var audio: Int64?
        for f in formats(root) {
            let vcodec = str(f, "vcodec")
            let acodec = str(f, "acodec")
            let s = size(f, duration: duration)
            if vcodec == "none" {
                if acodec != "none", let s, s > 0, s > (audio ?? 0) { audio = s }
                continue
            }
            // Preview images listed as formats (Weibo's scrubber JPEG, YouTube's storyboards) aren't qualities.
            if let ext = str(f, "ext"), ["jpg", "jpeg", "png", "webp"].contains(ext) { continue }
            if str(f, "protocol") == "mhtml" { continue }
            // The shorter side, as yt-dlp's "res" sort counts it: portrait 1080×1920 is 1080p, not 1920p.
            let width = Int(num(f, "width") ?? 0)
            var height = Int(num(f, "height") ?? 0)
            guard height > 0 else { continue }
            if width > 0 { height = min(width, height) }
            let fps = Int((num(f, "fps") ?? 0).rounded())
            let cur = byHeight[height] ?? (0, nil)
            byHeight[height] = (max(cur.fps, fps), maxOptional(cur.bytes, s))
            if let codec = VideoCodecs.family(vcodec) { codecs[codec] = max(codecs[codec] ?? 0, height) }
        }
        let list = byHeight.sorted { $0.key > $1.key }.map { key, value -> QualityOption in
            var est: Int64?
            if let b = value.bytes, b > 0 { est = b + (audio ?? 0) }
            return QualityOption(height: key, fps: value.fps, estimatedBytes: est)
        }
        return (list, audio, codecs)
    }

    /// Distinct audio track languages, the original (highest language_preference) first. Only meaningful when there is
    /// more than one (YouTube multi-language audio).
    private static func audioLanguages(_ root: [String: Any]) -> [String] {
        var best: [String: Double] = [:]
        var names: [String: String] = [:]
        for f in formats(root) {
            guard let acodec = str(f, "acodec"), acodec != "none", let language = str(f, "language"), !language.isEmpty else { continue }
            let key = language.lowercased()
            let preference = num(f, "language_preference") ?? 0
            best[key] = max(best[key] ?? -Double.infinity, preference)
            if names[key] == nil { names[key] = language }
        }
        guard best.count >= 2 else { return [] }
        return best.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.compactMap { names[$0.key] }
    }

    private static func size(_ f: [String: Any], duration: Double?) -> Int64? {
        if let s = num(f, "filesize"), s > 0 { return Int64(s) }
        if let a = num(f, "filesize_approx"), a > 0 { return Int64(a) }
        // tbr is in kbit/s.
        if let tbr = num(f, "tbr"), tbr > 0, let duration, duration > 0 { return Int64(tbr * 1000 / 8 * duration) }
        return nil
    }

    private static func maxOptional(_ a: Int64?, _ b: Int64?) -> Int64? {
        guard let a else { return b }
        guard let b else { return a }
        return max(a, b)
    }

    public static func pickThumbnail(_ root: [String: Any]) -> String? {
        var best: String?
        // yt-dlp sorts thumbnails worst → best; prefer the best JPEG since every system decodes it.
        for t in root["thumbnails"] as? [Any] ?? [] {
            if let t = t as? [String: Any], let u = str(t, "url"), u.containsIgnoringCase(".jpg") { best = u }
        }
        best = best ?? str(root, "thumbnail")
        if let b = best, b.hasPrefix("//") { best = "https:" + b }
        if let b = best, b.hasPrefix("http://") { best = "https://" + b.dropFirst(7) }
        return best
    }

    private static func str(_ e: [String: Any], _ name: String) -> String? { e[name] as? String }
    private static func num(_ e: [String: Any], _ name: String) -> Double? {
        guard let n = e[name] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }
}

/// yt-dlp's fast (--flat-playlist) listing of a Bilibili multi-part video has no part names or cover. One call to
/// Bilibili's public video-info endpoint fills them in, however many parts there are.
public enum BilibiliApi {
    private static let bvid = RX.make("BV[0-9A-Za-z]{10}")

    public static func enrich(_ playlist: PlaylistInfo, http: HTTPClient) async throws -> PlaylistInfo {
        guard let id = RX.firstGroups(bvid, in: playlist.url)?[0],
              let url = URL(string: "https://api.bilibili.com/x/web-interface/view?bvid=\(id)") else { return playlist }
        do {
            var req = URLRequest(url: url)
            req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
            let (data, _) = try await http.data(for: req)
            return applyView(playlist, json: String(decoding: data, as: UTF8.self))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.info("Bilibili part names unavailable: \(error.localizedDescription)")
            return playlist
        }
    }

    /// Merges the view API response into the playlist (pure; unit tested).
    public static func applyView(_ playlist: PlaylistInfo, json: String) -> PlaylistInfo {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let data = root["data"] as? [String: Any] else { return playlist }
        var parts: [Int: (name: String, duration: Double)] = [:]
        for p in data["pages"] as? [[String: Any]] ?? [] {
            if let page = (p["page"] as? NSNumber)?.intValue {
                parts[page] = (p["part"] as? String ?? "", (p["duration"] as? NSNumber)?.doubleValue ?? 0)
            }
        }
        var cover = data["pic"] as? String
        if let c = cover, c.hasPrefix("http://") { cover = "https://" + c.dropFirst(7) }
        let owner = (data["owner"] as? [String: Any])?["name"] as? String

        var out = playlist
        out.uploader = playlist.uploader ?? owner
        out.thumbnailURL = playlist.thumbnailURL ?? cover
        out.entries = playlist.entries.map { e in
            guard let p = parts[e.index], !p.name.isEmpty else { return e }
            return PlaylistEntry(index: e.index, url: e.url, title: "P\(e.index) \(p.name)",
                                 duration: e.duration ?? (p.duration > 0 ? p.duration : nil),
                                 thumbnailURL: e.thumbnailURL ?? cover)
        }
        return out
    }
}
