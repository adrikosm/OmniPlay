import Foundation

/// The decoders a game's media meets. Each engine family plays a different set; what it cannot play is converted
/// once, on the phone, into a form it does (see `MediaTranscode`).
public enum MediaEngine: String, Sendable, Codable, Hashable {
    /// WKWebView: RPG Maker MV/MZ, HTML5, Tyrano.
    case webKit
    /// mkxp-z: RPG Maker XP, VX, VX Ace.
    case mkxp
    /// Ren'Py's own FFmpeg build (all three engines decode the same set).
    case renpy
}

/// What a file is converted into.
public enum ConversionTarget: String, Sendable, Codable, Hashable {
    /// H.264 + AAC, for WebKit video.
    case mp4
    /// AAC audio in MP4, for WebKit.
    case m4a
    /// Theora + Vorbis, for mkxp-z and Ren'Py video.
    case ogv
    /// Vorbis audio, for mkxp-z and Ren'Py.
    case ogg
    /// For images an engine cannot load.
    case png

    public var fileExtension: String { rawValue }
}

public enum MediaKind: Sendable, Hashable { case video, audio, image }

/// Which files each engine plays as shipped and what the rest become. Measured, not assumed: every rule comes from
/// the media corpus (`Scripts/make-media-corpus.py`) played in each engine on the iOS 27 simulator, 21 Sep 2026.
///
/// - WebKit plays H.264, HEVC (`hvc1`), VP8, VP9 (WebM/MKV) and MJPEG video; Opus, MP3, AAC, ALAC, WAV, FLAC and AIFF
///   audio; every image format but TGA. Ogg Vorbis audio fails in WebKit, but the web runtime decodes it itself
///   (`OggVorbisDecoder`), so it counts as playing. VP9 WebM is still converted when no MP4 ships beside it: the
///   simulator plays it, which does not prove the phone does.
/// - mkxp-z plays Theora movies only; Vorbis, MP3, WAV (PCM and ADPCM), FLAC, AIFF and MIDI (FluidSynth) audio; PNG,
///   JPEG, BMP, GIF, TGA and SVG images.
/// - Ren'Py's FFmpeg decodes VP8, VP9, AV1, Theora, MPEG-1/2/4 and H.263 video and Opus, Vorbis, MP3, FLAC and PCM
///   audio. No H.264, HEVC, AAC, ALAC, WMA, AC-3, and no AIFF demuxer. Images: PNG, JPEG, still WebP, AVIF, BMP, GIF
///   and SVG; not HEIC, TIFF, TGA or animated WebP.
public enum MediaRules {
    public static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "webm", "mkv", "ogv", "avi", "wmv", "asf", "mpg", "mpeg", "m2v", "ts", "m2ts", "mts", "flv", "3gp", "vob",
        "divx",
    ]
    public static let audioExtensions: Set<String> = [
        "ogg", "oga", "opus", "mp3", "m4a", "aac", "wav", "flac", "aif", "aiff", "caf", "wma", "ac3", "mka", "weba", "mid", "midi",
    ]
    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "bmp", "gif", "tga", "svg", "webp", "avif", "heic", "heif", "tif", "tiff",
    ]

    public static func kind(of path: String) -> MediaKind? {
        let ext = pathExtension(path)
        if videoExtensions.contains(ext) {
            return .video
        }
        if audioExtensions.contains(ext) {
            return .audio
        }
        if imageExtensions.contains(ext) {
            return .image
        }
        return nil
    }

    /// Containers where the codec, not the extension, decides; everything else is judged by name.
    public static func needsProbe(_ path: String, engine: MediaEngine) -> Bool {
        let ext = pathExtension(path)
        switch engine {
        case .webKit: return ["mp4", "m4v", "mov", "webm", "mkv"].contains(ext)
        // Vorbis plays in Ogg, Opus does not; a WebM or MP4 may hold audio alone.
        case .mkxp: return ["ogg", "oga", "mp4", "m4v", "mov", "webm", "mkv"].contains(ext)
        // Animated WebP is refused where a still one loads.
        case .renpy: return ["mp4", "m4v", "mov", "webm", "mkv", "avi", "webp"].contains(ext)
        }
    }

    /// Nil when the engine plays the file as it is. `probe` is required where `needsProbe` says so.
    public static func conversion(for path: String, engine: MediaEngine, probe: MediaProbeResult?) -> ConversionTarget? {
        let ext = pathExtension(path)
        guard let kind = kind(of: path) else { return nil }
        let video = probe?.video
        let audio = probe?.audio
        switch (engine, kind) {
        case (.webKit, .video):
            switch ext {
            case "mp4", "m4v", "mov":
                guard let video else { return nil } // audio only: AAC, MP3 and ALAC all play
                if probe?.appleIncompatible == true {
                    return .mp4
                }
                // AV1 plays only where the chip decodes it (A17 Pro and later); converting costs one pass, once.
                return [.h264, .hevc].contains(video) ? nil : .mp4
            case "webm", "mkv":
                // WebKit plays Vorbis inside WebM video, but not in an audio-only file.
                guard let video else { return audio == .vorbis ? .m4a : nil }
                // H.264 has no alpha: a transparent VP9 overlay stays VP9, which WebKit composites as it is. VP8 plays,
                // except with Vorbis audio, where WebKit never finishes a seek, so looping and skipping stall (MEDIA-009).
                return (video == .vp8 && audio != .vorbis) || (video == .vp9 && probe?.hasAlpha == true) ? nil : .mp4
            default:
                return .mp4
            }
        case (.webKit, .audio):
            return ["wma", "ac3", "mka", "weba"].contains(ext) ? .m4a : nil
        case (.webKit, .image):
            return ext == "tga" ? .png : nil
        case (.mkxp, .video):
            if let probe, probe.video == nil, probe.audio != nil {
                return .ogg // audio in a video container
            }
            return ext == "ogv" ? nil : .ogv
        case (.mkxp, .audio):
            if ext == "ogg" || ext == "oga" {
                return audio == .opus ? .ogg : nil
            }
            return ["opus", "m4a", "aac", "caf", "wma", "ac3", "mka", "weba"].contains(ext) ? .ogg : nil
        case (.mkxp, .image):
            return ["webp", "avif", "heic", "heif", "tif", "tiff"].contains(ext) ? .png : nil
        case (.renpy, .video):
            switch ext {
            case "mp4", "m4v", "mov", "webm", "mkv":
                guard let probe else { return nil }
                guard let video else { return probe.audio == .aac || probe.audio == .unknown ? .ogg : nil }
                // A picture Ren'Py decodes with sound it cannot (AV1 with AAC) would play silent.
                let audioPlays = [nil, .vorbis, .opus, .mp3, .flac, .pcm].contains(probe.audio)
                return [.vp8, .vp9, .av1, .theora, .mpeg4].contains(video) && audioPlays ? nil : .ogv
            case "avi":
                // Ren'Py's FFmpeg has no Motion JPEG, H.264 or AC-3 decoder; Xvid and DivX play.
                guard let probe else { return nil }
                let audioPlays = [nil, .pcm, .mp3, .vorbis].contains(probe.audio)
                return (probe.video == nil || [.mpeg4, .vp8, .vp9].contains(video)) && audioPlays ? nil : .ogv
            case "wmv", "asf", "flv", "ts", "m2ts", "mts":
                return .ogv
            default:
                return nil // ogv, mpg: Ren'Py's own containers and codecs
            }
        case (.renpy, .audio):
            return ["m4a", "aac", "caf", "wma", "ac3", "aif", "aiff", "mka", "weba"].contains(ext) ? .ogg : nil
        case (.renpy, .image):
            if ext == "webp" {
                return probe?.animated == true ? .png : nil
            }
            return ["heic", "heif", "tif", "tiff", "tga"].contains(ext) ? .png : nil
        }
    }

    /// Extensions whose presence beside a file may mean the game already ships a form the engine plays; the sibling
    /// counts only when `conversion` passes it as it is.
    public static func playableSiblings(for kind: MediaKind, engine: MediaEngine) -> [String] {
        switch (engine, kind) {
        case (.webKit, .video): ["mp4", "m4v"]
        case (.webKit, .audio): ["m4a", "mp3", "ogg", "wav"]
        case (.webKit, .image): ["png"]
        case (.mkxp, .video): ["ogv"]
        case (.mkxp, .audio): ["ogg", "mp3", "wav", "mid"]
        case (.mkxp, .image): ["png", "jpg", "bmp"]
        case (.renpy, .video): ["webm", "ogv"]
        case (.renpy, .audio): ["ogg", "opus", "mp3", "wav"]
        case (.renpy, .image): ["png", "jpg", "webp"]
        }
    }

    /// Where the converted file goes, relative to the game root like its source: the same name with the target's
    /// extension, in the Generated layer.
    public static func outputPath(for source: String, target: ConversionTarget) -> String {
        let ext = pathExtension(source)
        let stem = ext.isEmpty ? source : String(source.dropLast(ext.count + 1))
        return stem + "." + target.fileExtension
    }

    public static func pathExtension(_ path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }
}
