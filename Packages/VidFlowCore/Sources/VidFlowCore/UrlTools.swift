import Foundation

public enum UrlTools {
    private static let urlRegex = RX.make(#"https?://[^\s"'<>，。【】]+"#, ignoreCase: true)

    /// Pulls the first URL out of pasted share text such as "【标题】 https://b23.tv/xxx".
    public static func extractURL(_ text: String?) -> String? { extractURLs(text).first }

    /// All distinct URLs in the text, in order (for batch pasting).
    public static func extractURLs(_ text: String?) -> [String] {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        var urls: [String] = []
        for m in urlRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var url = ns.substring(with: m.range)
            while let last = url.last, ".,)]".contains(last) { url.removeLast() }
            if seen.insert(url).inserted { urls.append(url) }
        }
        return urls
    }

    public static func isSupported(_ url: String?) -> Bool { url.map { detectPlatform($0) != .other } ?? false }

    /// Each platform's domains, including its link shorteners.
    private static let domains: [(Platform, [String])] = [
        (.youTube, ["youtube.com", "youtu.be", "youtube-nocookie.com"]),
        (.bilibili, ["bilibili.com", "b23.tv"]),
        (.douyin, ["douyin.com", "iesdouyin.com"]),
        (.weibo, ["weibo.com", "weibo.cn", "t.cn"]),
        (.xiaohongshu, ["xiaohongshu.com", "xhslink.com"]),
        (.x, ["x.com", "twitter.com", "t.co"]),
    ]

    /// Shorteners whose redirects VidFlow follows itself (yt-dlp can't: they end on a login or visitor check page, or
    /// need the id rewritten).
    private static let shortLinkHosts = ["v.douyin.com", "t.cn", "xhslink.com"]

    private static func host(_ url: String) -> String? {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)), u.scheme != nil else { return nil }
        return u.host?.lowercased()
    }

    /// By host name: "x.com" must not match netflix.com.
    public static func detectPlatform(_ url: String) -> Platform {
        guard let host = host(url) else { return .other }
        for (platform, names) in domains where names.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return platform
        }
        return .other
    }

    public static func isShortLink(_ url: String) -> Bool { host(url).map(shortLinkHosts.contains) ?? false }

    private static let douyinID = RX.make(#"(?:/video/|/share/video/|[?&]modal_id=|[?&]vid=)(\d{15,20})"#)

    /// yt-dlp only understands douyin.com/video/ID. Douyin links come in several other shapes: the feed
    /// (douyin.com/jingxuan?modal_id=ID), share pages (iesdouyin.com/share/video/ID) and short links
    /// (v.douyin.com/xxxx, see `ShortLinks`). Returns the canonical link, or nil if there is no video id.
    public static func canonicalDouyinURL(_ url: String) -> String? {
        RX.firstGroups(douyinID, in: url)?[1].map { "https://www.douyin.com/video/\($0)" }
    }

    private static let weiboID = RX.make(#"(?:/tv/show/|[?&]fid=)(\d+(?::|%3A)\d+)"#, ignoreCase: true)

    /// Weibo's old video page (video.weibo.com/show?fid=1034:ID, where its t.cn links lead) becomes the
    /// weibo.com/tv/show/1034:ID page yt-dlp reads. Other Weibo links (posts) are left alone.
    public static func canonicalWeiboURL(_ url: String) -> String? {
        RX.firstGroups(weiboID, in: url)?[1].map {
            "https://weibo.com/tv/show/\($0.replacingOccurrences(of: "%3A", with: ":").replacingOccurrences(of: "%3a", with: ":"))"
        }
    }

    /// The link yt-dlp (or VidFlow's Douyin reader) should get, when it can be rewritten without the network.
    public static func canonical(_ url: String) -> String? {
        switch detectPlatform(url) {
        case .douyin: canonicalDouyinURL(url)
        case .weibo: canonicalWeiboURL(url)
        default: nil
        }
    }

    /// A YouTube watch link that also carries a playlist (watch?v=…&list=…): we treat it as the single video.
    public static func isYouTubeVideoInPlaylist(_ url: String) -> Bool {
        detectPlatform(url) == .youTube && url.contains("v=") && url.contains("list=")
    }

    private static let invalidFolderCharacters = CharacterSet(charactersIn: "/:\\<>\"|?*").union(.controlCharacters)

    /// A playlist's title as a folder name.
    public static func safeFolderName(_ name: String) -> String {
        var clean = String(String.UnicodeScalarView(name.unicodeScalars.map {
            invalidFolderCharacters.contains($0) ? "_" : $0
        })).trimmingCharacters(in: .whitespaces)
        while clean.hasSuffix(".") { clean.removeLast() }
        // A leading dot would hide the folder in Finder.
        while clean.hasPrefix(".") { clean.removeFirst() }
        if clean.isEmpty { return "Playlist" }
        return clean.count > 80 ? String(clean.prefix(80)) : clean
    }
}

/// Reads the response of Douyin's web "aweme/detail" API (fetched by its own page script, see the app's
/// DouyinFetcher), and picks the stream to download. yt-dlp's Douyin support can't sign these requests any more.
public struct DouyinStream: Equatable, Sendable {
    public var url: String
    public var width: Int
    public var height: Int
    public var bitrate: Int64
    public var size: Int64?
    public var h265: Bool
    /// Douyin videos are mostly portrait: the short side is what people call 1080p.
    public var resolution: Int { min(width, height) }

    public init(url: String, width: Int, height: Int, bitrate: Int64, size: Int64?, h265: Bool) {
        self.url = url
        self.width = width
        self.height = height
        self.bitrate = bitrate
        self.size = size
        self.h265 = h265
    }
}

public struct DouyinVideo: Equatable, Sendable {
    public var id: String
    public var title: String
    public var author: String?
    public var uploadDate: String?
    public var duration: Double?
    public var cover: String?
    public var streams: [DouyinStream]
}

public enum DouyinParser {
    public static func parse(_ json: String) throws -> DouyinVideo {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let a = root["aweme_detail"] as? [String: Any] else {
            throw YtDlpError(L.get("Error_DouyinUnavailable"))
        }
        let id = a["aweme_id"] as? String ?? ""
        var title = (a["desc"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = "Douyin \(id)" }
        let author = (a["author"] as? [String: Any])?["nickname"] as? String
        var date: String?
        if let secs = (a["create_time"] as? NSNumber)?.int64Value, secs > 0 {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd"
            date = f.string(from: Date(timeIntervalSince1970: TimeInterval(secs)))
        }
        guard let v = a["video"] as? [String: Any], ((a["images"] as? [Any])?.count ?? 0) == 0 else {
            throw YtDlpError(L.get("Error_DouyinNotVideo"))
        }
        var streams: [DouyinStream] = []
        for r in v["bit_rate"] as? [[String: Any]] ?? [] {
            if let addr = r["play_addr"] as? [String: Any],
               let s = stream(addr, bitrate: long(r, "bit_rate"), h265: long(r, "is_h265") == 1) { streams.append(s) }
        }
        // Older / simpler answers only have the default address.
        if streams.isEmpty, let play = v["play_addr"] as? [String: Any], let s = stream(play, bitrate: 0, h265: false) {
            streams.append(s)
        }
        if streams.isEmpty { throw YtDlpError(L.get("Error_DouyinUnavailable")) }

        let ms = long(v, "duration")
        var cover: String?
        for key in ["origin_cover", "cover", "dynamic_cover"] where cover == nil {
            cover = (v[key] as? [String: Any]).flatMap { urls($0).first }
        }
        return DouyinVideo(id: id, title: title, author: author, uploadDate: date, duration: ms > 0 ? Double(ms) / 1000 : nil,
                           cover: cover, streams: sorted(streams))
    }

    private static func sorted(_ s: [DouyinStream]) -> [DouyinStream] {
        s.sorted { ($0.resolution, $0.bitrate) > ($1.resolution, $1.bitrate) }
    }

    private static func stream(_ addr: [String: Any], bitrate: Int64, h265: Bool) -> DouyinStream? {
        let list = urls(addr)
        guard let first = list.first else { return nil }
        // Prefer a CDN address over douyin.com/aweme/v1/play (a redirect that sometimes refuses non-browser clients).
        let url = list.first { !$0.contains("/aweme/v1/play") } ?? first
        let size = long(addr, "data_size")
        return DouyinStream(url: url, width: Int(long(addr, "width")), height: Int(long(addr, "height")), bitrate: bitrate,
                            size: size > 0 ? size : nil, h265: h265)
    }

    /// The stream that fits the request: within the resolution limit (if any), the codec asked for when offered
    /// (H.264 for compatibility mode), otherwise the highest resolution and bitrate.
    public static func pick(_ video: DouyinVideo, maxHeight: Int, codec: String) -> DouyinStream {
        var fitting = video.streams.filter { maxHeight <= 0 || $0.resolution <= maxHeight }
        if fitting.isEmpty, let lowest = video.streams.min(by: { $0.resolution < $1.resolution }) { fitting = [lowest] }
        let wanted = switch codec {
        case "h264": fitting.filter { !$0.h265 }
        case "h265": fitting.filter(\.h265)
        default: fitting
        }
        return sorted(wanted.isEmpty ? fitting : wanted)[0]
    }

    /// The same shape the yt-dlp path produces, so the rest of the app needn't know.
    public static func toVideoInfo(_ v: DouyinVideo) -> VideoInfo {
        var info = VideoInfo(url: "https://www.douyin.com/video/\(v.id)", title: v.title)
        info.uploader = v.author
        info.uploadDate = v.uploadDate
        info.duration = v.duration
        info.thumbnailURL = v.cover
        info.platform = .douyin
        info.qualities = Dictionary(grouping: v.streams, by: \.resolution)
            .map { QualityOption(height: $0.key, fps: 0, estimatedBytes: $0.value.compactMap(\.size).max()) }
            .sorted { $0.height > $1.height }
        info.codecs = Dictionary(grouping: v.streams) { $0.h265 ? "h265" : "h264" }
            .mapValues { $0.map(\.resolution).max() ?? 0 }
        return info
    }

    private static func urls(_ e: [String: Any]) -> [String] {
        (e["url_list"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
    }

    private static func long(_ e: [String: Any], _ name: String) -> Int64 { (e[name] as? NSNumber)?.int64Value ?? 0 }
}
