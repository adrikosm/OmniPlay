import CTranscode
import Foundation

/// The four shapes OmniPlay converts media into, one per engine family's decoder.
public enum MediaTarget: String, Sendable, Codable, Hashable {
    /// WebKit: H.264 (VideoToolbox) and AAC in MP4.
    case mp4H264AAC
    /// mkxp-z and Ren'Py: Theora and Vorbis in Ogg, which both decode with their own libraries.
    case ogvTheoraVorbis
    /// Audio for mkxp-z and Ren'Py.
    case oggVorbis
    /// Audio for anything.
    case wavPCM

    public var fileExtension: String {
        switch self {
        case .mp4H264AAC: "mp4"
        case .ogvTheoraVorbis: "ogv"
        case .oggVorbis: "ogg"
        case .wavPCM: "wav"
        }
    }

    var c: op_target {
        switch self {
        case .mp4H264AAC: OP_TARGET_MP4_H264_AAC
        case .ogvTheoraVorbis: OP_TARGET_OGV_THEORA_VORBIS
        case .oggVorbis: OP_TARGET_OGG_VORBIS
        case .wavPCM: OP_TARGET_WAV_PCM
        }
    }
}

public struct TranscodeSpec: Sendable, Codable, Hashable {
    public var target: MediaTarget
    /// 0 keeps the source size; larger frames shrink into the box.
    public var maxWidth = 0
    public var maxHeight = 0
    public var maxFPS = 0
    /// Theora quality 0...10, or H.264 bits per second; 0 picks a default.
    public var videoQuality = 0
    /// Vorbis quality 0...10, or AAC bits per second; 0 picks a default.
    public var audioQuality = 0

    public init(target: MediaTarget, maxWidth: Int = 0, maxHeight: Int = 0, maxFPS: Int = 0, videoQuality: Int = 0, audioQuality: Int = 0) {
        self.target = target
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.maxFPS = maxFPS
        self.videoQuality = videoQuality
        self.audioQuality = audioQuality
    }
}

/// File-to-file conversion over `op_transcode.c`. Synchronous and CPU-heavy: call it off the main actor. The output
/// appears whole or not at all (written beside it as `.partial`, then moved).
public enum MediaTranscoder {
    public struct Failure: Error, CustomStringConvertible, Sendable {
        public let code: Int32
        public let message: String
        public var cancelled: Bool { code == OP_TRANSCODE_CANCELLED }
        public var permanent: Bool { op_transcode_permanent(code) != 0 }
        public var description: String { message }
    }

    private final class Box {
        let progress: (Double) -> Bool
        init(_ progress: @escaping (Double) -> Bool) { self.progress = progress }
    }

    /// `progress` gets the fraction done (or -1 when the length is unknown) and returns false to cancel.
    public static func transcode(
        _ input: URL,
        to output: URL,
        spec: TranscodeSpec,
        progress: @escaping (Double) -> Bool = { _ in true }
    ) throws {
        let partial = output.appendingPathExtension("partial")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: partial)
        var c = op_transcode_spec(
            target: spec.target.c,
            max_width: Int32(spec.maxWidth),
            max_height: Int32(spec.maxHeight),
            max_fps: Int32(spec.maxFPS),
            video_quality: Int32(spec.videoQuality),
            audio_quality: Int32(spec.audioQuality)
        )
        let box = Box(progress)
        var message = [CChar](repeating: 0, count: 512)
        let code = op_transcode(
            input.path(percentEncoded: false), partial.path(percentEncoded: false), &c,
            { context, fraction in
                Unmanaged<Box>.fromOpaque(context!).takeUnretainedValue().progress(fraction) ? 0 : 1
            },
            Unmanaged.passUnretained(box).toOpaque(), &message, Int32(message.count)
        )
        withExtendedLifetime(box) {}
        guard code == 0 else {
            try? FileManager.default.removeItem(at: partial)
            let text = String(bytes: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
            throw Failure(code: code, message: text)
        }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: partial, to: output)
    }
}
