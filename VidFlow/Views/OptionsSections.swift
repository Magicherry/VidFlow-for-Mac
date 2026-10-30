import SwiftUI
import VidFlowCore

/// Edits download options in place on a `DownloadTemplate`. Given a parsed video, the quality, codec and audio-track
/// lists show only what that video offers; otherwise generic choices. Goes inside a Form.
struct OptionsSections: View {
    @Binding var options: DownloadTemplate
    var video: VideoInfo?
    var showNaming: Bool

    private static let genericHeights = [2160, 1440, 1080, 720, 480, 360]
    private static let audioQualities = [0, 320, 256, 192, 128, 96]
    private static let customPreset = "\0custom"

    var body: some View {
        Section {
            Picker(L.get("Options_Mode"), selection: mode) {
                Text(L.get("Mode_Video")).tag("video")
                Text(L.get("Mode_Audio")).tag("audio")
                Text(L.get("Mode_Cover")).tag("cover")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            compatibility
        }

        if options.mode == "video" {
            Section {
                Picker(L.get("Options_Quality"), selection: quality) {
                    ForEach(qualityChoices, id: \.tag) { Text($0.text).tag($0.tag) }
                }
                Picker(L.get("Options_Container"), selection: $options.container) {
                    Text("MP4").tag("mp4")
                    Text("MKV").tag("mkv")
                    Text("WebM").tag("webm")
                }
                Picker(L.get("Options_Codec"), selection: $options.codec) {
                    ForEach(codecChoices, id: \.tag) { Text($0.text).tag($0.tag) }
                }
            }
        }

        if options.mode != "cover" {
            Section {
                Toggle(L.get("Options_Subtitles"), isOn: $options.subtitles)
                DisclosureGroup(L.get("Options_Advanced")) {
                    if options.mode == "video", video == nil || video?.hdrKinds.isEmpty == false {
                        Picker(L.get("Options_Picture"), selection: $options.dynamicRange) {
                            ForEach(pictureChoices, id: \.tag) { Text($0.text).tag($0.tag) }
                        }
                    }
                    Picker(L.get("Options_AudioFormat"), selection: $options.audioFormat) {
                        ForEach(audioFormatChoices, id: \.tag) { Text($0.text).tag($0.tag) }
                    }
                    Picker(L.get("Options_AudioQuality"), selection: $options.audioQuality) {
                        ForEach(Self.audioQualities, id: \.self) { q in
                            Text(q == 0 ? L.get("AudioQuality_Best") : "\(q) kbps").tag(q)
                        }
                    }
                    Picker(L.get("Options_AudioTrack"), selection: $options.audioLanguage) {
                        Text(L.get("AudioTrack_Default")).tag("")
                        ForEach(languageChoices, id: \.self) { Text(Self.languageName($0)).tag($0) }
                    }
                    if options.mode == "video" {
                        Toggle(L.get("Options_Recode"), isOn: $options.recode)
                            .help(L.get("Options_RecodeDescription"))
                    }
                }
            }
        }

        if showNaming { naming }
    }

    // ---- Naming -------------------------------------------------------------------------------------------------

    private var naming: some View {
        Section(L.get("Options_Naming")) {
            Picker(L.get("Options_FileName"), selection: filePreset) {
                ForEach(NamingTemplate.filePresets, id: \.self) { preset in
                    let text = Self.describe(preset)
                    Text(preset == NamingTemplate.defaultFileName ? L.format("Naming_Recommended", text) : text).tag(preset)
                }
                Text(L.get("Naming_Custom")).tag(Self.customPreset)
            }
            HStack {
                TextField(L.get("Options_FileNamePattern"), text: $options.fileNameTemplate, prompt: Text(L.get("Options_FileNamePlaceholder")))
                    .labelsHidden()
                Menu {
                    ForEach(NamingTemplate.variables, id: \.self) { v in
                        Button(L.get("Var_\(v)")) { insert(v) }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L.get("Options_Insert"))
                .accessibilityLabel(L.get("Options_Insert"))
            }
            let unknown = NamingTemplate.unknownVariables(options.fileNameTemplate)
            if !unknown.isEmpty {
                Text(L.format("Naming_Unknown", unknown.map { "{\($0)}" }.joined(separator: " ")))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Picker(L.get("Options_Subfolder"), selection: $options.folderTemplate) {
                Text(L.get("Folder_None")).tag("")
                Text(L.get("Folder_Platform")).tag("{platform}")
                Text(L.get("Folder_Uploader")).tag("{uploader}")
                Text(L.get("Folder_Month")).tag("{year}-{month}")
                Text(L.get("Folder_PlatformUploader")).tag("{platform}/{uploader}")
                if !NamingTemplate.folderPresets.contains(options.folderTemplate) {
                    Text(options.folderTemplate).tag(options.folderTemplate)
                }
            }
            LabeledContent(L.get("Options_PreviewHeader")) {
                Text(NamingTemplate.preview(fileTemplate: options.fileNameTemplate, folderTemplate: options.folderTemplate, ext: previewExtension))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
    }

    private var filePreset: Binding<String> {
        Binding {
            let text = options.fileNameTemplate.trimmingCharacters(in: .whitespaces)
            return NamingTemplate.filePresets.contains(text) ? text : Self.customPreset
        } set: { value in
            if value != Self.customPreset { options.fileNameTemplate = value }
        }
    }

    /// Adds "{variable}", with a space before it if needed.
    private func insert(_ name: String) {
        var text = options.fileNameTemplate
        if let last = text.last, !last.isWhitespace, !"([-_".contains(last) { text += " " }
        options.fileNameTemplate = text + "{\(name)}"
    }

    /// "{uploader} - {title}" → "Uploader - Title".
    private static func describe(_ pattern: String) -> String {
        NamingTemplate.variables.reduce(pattern) { $0.replacingOccurrences(of: "{\($1)}", with: L.get("Var_\($1)")) }
    }

    private var previewExtension: String {
        switch options.mode {
        case "cover": "jpg"
        case "video": options.toRequest(url: "", baseFolder: "").needsMkv ? "mkv" : options.container
        default: options.audioFormat == MediaFeatures.original ? (video?.hasHiRes == true ? "flac" : "m4a") : options.audioFormat
        }
    }

    // ---- Compatibility ------------------------------------------------------------------------------------------

    @ViewBuilder private var compatibility: some View {
        if let issue = FormatCompatibility.check(options, video: video) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: issue.info ? "info.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(issue.info ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    .accessibilityHidden(true)
                Text(L.get(issue.messageKey)).font(.callout)
                Spacer(minLength: 4)
                if issue.suggestedContainer != nil || issue.suggestedAudioFormat != nil {
                    Button(L.get(issue.info ? "Compat_UseMkv" : "Compat_Apply")) {
                        if let c = issue.suggestedContainer { options.container = c }
                        if let a = issue.suggestedAudioFormat { options.audioFormat = a }
                    }
                }
            }
        }
    }

    // ---- Choices ------------------------------------------------------------------------------------------------

    private struct Choice {
        var tag: String
        var text: String
    }

    struct IntChoice {
        var tag: Int
        var text: String
    }

    /// Video and audio-only have different audio format choices.
    var mode: Binding<String> {
        Binding {
            options.mode == "audio" || options.mode == "cover" ? options.mode : "video"
        } set: { value in
            options.mode = value
            if value == "audio" {
                if !["mp3", "m4a", "opus", "flac", "wav", MediaFeatures.original].contains(options.audioFormat) { options.audioFormat = "mp3" }
            } else if !["auto", "aac", "opus", MediaFeatures.hiRes, MediaFeatures.atmos].contains(options.audioFormat) {
                options.audioFormat = "auto"
            }
        }
    }

    /// The parsed video's highest resolution (the first, "best" entry); unknown before parsing.
    private var topHeight: Int { video?.qualities.first?.height ?? .max }

    var qualityChoices: [IntChoice] {
        if let v = video, let top = v.qualities.first {
            // The top resolution is "best" (0) itself: listing both would show it twice.
            return [IntChoice(tag: 0, text: Format.quality(top))]
                + v.qualities.dropFirst().map { IntChoice(tag: $0.height, text: Format.quality($0)) }
        }
        return [IntChoice(tag: 0, text: L.get("Quality_Best"))] + Self.genericHeights.map { IntChoice(tag: $0, text: Format.height($0)) }
    }

    /// Closest choice not above the wanted height (a 1080p template on a 720p video shows 720p). The first entry stands
    /// for both "best" and the top resolution: a 1080p template on a 1080p video keeps its 1080.
    var quality: Binding<Int> {
        Binding {
            if options.maxHeight == 0 || options.maxHeight >= topHeight { return 0 }
            return qualityChoices.first { $0.tag > 0 && $0.tag <= options.maxHeight }?.tag ?? 0
        } set: { value in
            if value != 0 || options.maxHeight < topHeight { options.maxHeight = value }
        }
    }

    private var codecChoices: [Choice] {
        var list = [Choice(tag: VideoCodecs.auto, text: VideoCodecs.displayName(VideoCodecs.auto))]
        for codec in VideoCodecs.all {
            if let video {
                if let max = video.codecs[codec] {
                    list.append(Choice(tag: codec, text: L.format("Codec_WithMax", VideoCodecs.displayName(codec), max)))
                }
            } else {
                list.append(Choice(tag: codec, text: VideoCodecs.displayName(codec)))
            }
        }
        // A codec this video doesn't offer: keep it visible so it's clear the download will fall back.
        if !list.contains(where: { $0.tag == options.codec }) {
            list.append(Choice(tag: options.codec, text: L.format("Codec_Unavailable", VideoCodecs.displayName(options.codec))))
        }
        return list
    }

    private var pictureChoices: [Choice] {
        let hdr = video == nil || video?.hasHdr == true
        let dv = video == nil || video?.hasDolbyVision == true
        var list = [Choice(tag: MediaFeatures.auto, text: L.get(hdr ? "Picture_Auto" : "Picture_AutoNoHdr"))]
        if dv { list.append(Choice(tag: MediaFeatures.dolbyVision, text: L.get("Picture_DolbyVision"))) }
        list.append(Choice(tag: MediaFeatures.sdr, text: L.get("Picture_Sdr")))
        if options.dynamicRange == MediaFeatures.dolbyVision, !dv {
            list.append(Choice(tag: MediaFeatures.dolbyVision, text: L.format("Codec_Unavailable", L.get("Picture_DolbyVision"))))
        }
        return list
    }

    private var audioFormatChoices: [Choice] {
        if options.mode == "audio" {
            return [
                Choice(tag: MediaFeatures.original, text: L.get("AudioFormat_Original")), Choice(tag: "mp3", text: "MP3"),
                Choice(tag: "m4a", text: "M4A (AAC)"), Choice(tag: "opus", text: "Opus"),
                Choice(tag: "flac", text: L.get("AudioFormat_Flac")), Choice(tag: "wav", text: "WAV"),
            ]
        }
        var list = [Choice(tag: "auto", text: L.get("AudioFormat_Auto")), Choice(tag: "aac", text: "AAC"), Choice(tag: "opus", text: "Opus")]
        // Hi-Res / Dolby Atmos: when the video offers them (always listed in the template editor).
        if video == nil || video?.hasHiRes == true { list.append(Choice(tag: MediaFeatures.hiRes, text: L.get("AudioFormat_HiRes"))) }
        if video == nil || video?.hasAtmos == true { list.append(Choice(tag: MediaFeatures.atmos, text: L.get("AudioFormat_Atmos"))) }
        // Chosen in a template but not offered by this video: keep it visible, the download falls back.
        if !list.contains(where: { $0.tag == options.audioFormat }) {
            let key = options.audioFormat == MediaFeatures.hiRes ? "AudioFormat_HiRes" : "AudioFormat_Atmos"
            list.append(Choice(tag: options.audioFormat, text: L.format("Codec_Unavailable", L.get(key))))
        }
        return list
    }

    private var languageChoices: [String] {
        var languages = video?.audioLanguages ?? []
        if !options.audioLanguage.isEmpty, !languages.contains(where: { $0.caseInsensitiveCompare(options.audioLanguage) == .orderedSame }) {
            languages.append(options.audioLanguage)
        } else if video == nil {
            for common in ["zh", "en", "ja", "ko"] where !languages.contains(common) { languages.append(common) }
        }
        return languages
    }

    private static func languageName(_ code: String) -> String {
        let locale = Locale(identifier: code)
        if let name = locale.localizedString(forIdentifier: code), name != code { return "\(name) (\(code))" }
        return code
    }
}
