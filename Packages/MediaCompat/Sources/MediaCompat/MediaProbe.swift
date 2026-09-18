/// Media facts that drive per-runtime normalisation (design authority §12). The load-bearing one:
/// WKWebView on iPhone cannot play VP9 WebM, so MZ titles with WebM cutscenes need a transcode
/// or sibling selection before first launch.
public enum VideoCodec: String, Codable, Sendable, CaseIterable {
    case h264
    case hevc
    case vp8
    case vp9
    case av1
    case theora
    case unknown
}

public enum AudioCodec: String, Codable, Sendable, CaseIterable {
    case aac
    case mp3
    case vorbis
    case opus
    case flac
    case pcm
    case unknown
}

public enum MediaContainer: String, Codable, Sendable, CaseIterable {
    case mp4
    case webm
    case ogg
    case ogv
    case m4a
    case wav
    case unknown
}

public struct MediaProbeResult: Codable, Sendable, Hashable {
    /// Relative path inside the game tree.
    public let path: String
    public let container: MediaContainer
    public let video: VideoCodec?
    public let audio: AudioCodec?
    public let hasAlpha: Bool

    public init(path: String, container: MediaContainer, video: VideoCodec?, audio: AudioCodec?, hasAlpha: Bool = false) {
        self.path = path
        self.container = container
        self.video = video
        self.audio = audio
        self.hasAlpha = hasAlpha
    }
}

/// What the pipeline decided to do with one asset. Results land in `Generated/` (§12.4).
public enum MediaDecision: Sendable, Hashable {
    case playNative
    case useSibling(path: String)
    case transcode(container: MediaContainer, video: VideoCodec?, audio: AudioCodec?)
    case unsupported(reason: String)
}
