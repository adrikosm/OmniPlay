import Foundation
import GameCore

/// Media facts that drive per-runtime normalisation. The load-bearing one: WKWebView on iPhone does not play
/// VP9 WebM, so MZ titles with WebM cutscenes need a transcode or an MP4 sibling before first launch.
public enum VideoCodec: String, Codable, Sendable, CaseIterable { case h264, hevc, vp8, vp9, av1, theora, unknown }
public enum AudioCodec: String, Codable, Sendable, CaseIterable { case aac, mp3, vorbis, opus, flac, pcm, unknown }
public enum MediaContainer: String, Codable, Sendable, CaseIterable { case mp4, webm, ogg, ogv, m4a, wav, mp3, midi, unknown }

public struct MediaProbeResult: Codable, Sendable, Hashable {
    /// Relative path inside the game tree.
    public let path: String
    public let container: MediaContainer
    public let video: VideoCodec?
    public let audio: AudioCodec?
    public let hasAlpha: Bool
    public var bytes: Int64 = 0

    public init(path: String, container: MediaContainer, video: VideoCodec?, audio: AudioCodec?, hasAlpha: Bool = false, bytes: Int64 = 0) {
        self.path = path
        self.container = container
        self.video = video
        self.audio = audio
        self.hasAlpha = hasAlpha
        self.bytes = bytes
    }
}

/// What the pipeline decided to do with one asset. Results land in `Generated/`.
public enum MediaDecision: Sendable, Hashable {
    case playNative
    case useSibling(path: String)
    case transcode(container: MediaContainer, video: VideoCodec?, audio: AudioCodec?)
    case unsupported(reason: String)
}

/// Header-only identification: at most 2 MiB from the head and, for MP4 with a trailing `moov`, 2 MiB from the tail.
/// Never throws for corrupt media; unknown is an answer.
public enum MediaProbe {
    public static let window = 2 << 20

    public static func probe(_ url: URL, relativePath: String) -> MediaProbeResult {
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard let head = try? read(url, offset: 0, count: window) else { return MediaProbeResult(
            path: relativePath,
            container: .unknown,
            video: nil,
            audio: nil,
            bytes: size
        ) }
        var result = identify(head, path: relativePath)
        if result.container == .mp4 || result.container == .m4a, result.video == nil, result.audio == nil, size > Int64(head.count),
           let tail = try? read(url, offset: max(0, size - Int64(window)), count: window) {
            let codecs = MP4.codecs(in: tail)
            result = MediaProbeResult(
                path: relativePath,
                container: result.container,
                video: codecs.video,
                audio: codecs.audio,
                bytes: size
            )
        }
        result.bytes = size
        return result
    }

    public static func identify(_ d: Data, path: String) -> MediaProbeResult {
        func at(
            _ o: Int,
            _ s: String
        ) -> Bool { d.count >= o + s.utf8.count && d[d.startIndex + o ..< d.startIndex + o + s.utf8.count]
            .elementsEqual(s.utf8)
        }
        if d.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) {
            let ids = EBML.codecIDs(d)
            let video = ids.compactMap(EBML.video).first
            let audio = ids.compactMap(EBML.audio).first
            return MediaProbeResult(path: path, container: .webm, video: video, audio: audio)
        }
        if at(4, "ftyp") {
            let brand = String(bytes: d[d.startIndex + 8 ..< min(d.startIndex + 12, d.endIndex)], encoding: .ascii) ?? ""
            let codecs = MP4.codecs(in: d)
            let container: MediaContainer = brand
                .hasPrefix("M4A") || (codecs.video == nil && codecs.audio != nil && path.lowercased().hasSuffix(".m4a")) ? .m4a : .mp4
            return MediaProbeResult(path: path, container: container, video: codecs.video, audio: codecs.audio)
        }
        if d.starts(with: "OggS".utf8) {
            let body = d.dropFirst(27)
            if body.range(of: Data("\u{01}vorbis".utf8)) != nil {
                return MediaProbeResult(
                    path: path,
                    container: .ogg,
                    video: nil,
                    audio: .vorbis
                )
            }
            if body
                .range(of: Data("OpusHead".utf8)) != nil {
                return MediaProbeResult(path: path, container: .ogg, video: nil, audio: .opus)
            }
            if body.range(of: Data("\u{80}theora".utf8)) != nil {
                return MediaProbeResult(
                    path: path,
                    container: .ogv,
                    video: .theora,
                    audio: d.range(of: Data("\u{01}vorbis".utf8)) != nil ? .vorbis : nil
                )
            }
            return MediaProbeResult(path: path, container: .ogg, video: nil, audio: .unknown)
        }
        if d
            .starts(with: "ID3".utf8) ||
            (d.count > 1 && d[d.startIndex] == 0xFF && d[d.startIndex + 1] & 0xE0 == 0xE0) {
            return MediaProbeResult(
                path: path,
                container: .mp3,
                video: nil,
                audio: .mp3
            )
        }
        if d.starts(with: "RIFF".utf8), at(8, "WAVE") {
            return MediaProbeResult(path: path, container: .wav, video: nil, audio: .pcm)
        }
        if d.starts(with: "MThd".utf8) {
            return MediaProbeResult(path: path, container: .midi, video: nil, audio: nil)
        }
        return MediaProbeResult(path: path, container: .unknown, video: nil, audio: nil)
    }

    private static func read(_ url: URL, offset: Int64, count: Int) throws -> Data {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        try h.seek(toOffset: UInt64(offset))
        return try h.read(upToCount: count) ?? Data()
    }

    /// Minimal EBML walker: descends Segment → Tracks → TrackEntry and collects CodecID strings.
    enum EBML {
        static let segment: [UInt8] = [0x18, 0x53, 0x80, 0x67], tracks: [UInt8] = [0x16, 0x54, 0xAE, 0x6B], trackEntry: [UInt8] = [0xAE],
                   codecID: [UInt8] = [0x86]
        static let containers: Set<[UInt8]> = [segment, tracks, trackEntry]

        static func codecIDs(_ d: Data) -> [String] {
            var out: [String] = []
            walk(d, d.startIndex, d.endIndex, depth: 0, into: &out)
            return out
        }

        private static func walk(_ d: Data, _ start: Data.Index, _ end: Data.Index, depth: Int, into out: inout [String]) {
            var i = start
            while i < end, out.count < 16, depth < 6 {
                guard let (id, afterID) = readID(d, i), let (size, afterSize) = readSize(d, afterID) else { return }
                let bodyEnd = size == nil ? end : min(end, afterSize.advanced(by: Int(min(size!, UInt64(end - afterSize)))))
                if id == codecID, let s = String(bytes: d[afterSize ..< bodyEnd], encoding: .ascii) {
                    out.append(s)
                } else if containers.contains(id) {
                    walk(d, afterSize, bodyEnd, depth: depth + 1, into: &out)
                }
                if size == nil {
                    return
                }
                i = bodyEnd
            }
        }

        private static func readID(_ d: Data, _ i: Data.Index) -> ([UInt8], Data.Index)? {
            guard i < d.endIndex else { return nil }
            let first = d[i]
            let len = first >= 0x80 ? 1 : first >= 0x40 ? 2 : first >= 0x20 ? 3 : first >= 0x10 ? 4 : 0
            guard len > 0, i + len <= d.endIndex else { return nil }
            return (Array(d[i ..< i + len]), i + len)
        }

        /// Returns nil size for the "unknown size" marker (all value bits set).
        private static func readSize(_ d: Data, _ i: Data.Index) -> (UInt64?, Data.Index)? {
            guard i < d.endIndex else { return nil }
            let first = d[i]
            var len = 1
            var mask: UInt8 = 0x80
            while len <= 8, first & mask == 0 {
                len += 1; mask >>= 1
            }
            guard len <= 8, i + len <= d.endIndex else { return nil }
            var value = UInt64(first & (mask - 1))
            var allOnes = value == UInt64(mask - 1)
            for k in 1 ..< len {
                value = value << 8 | UInt64(d[i + k]); allOnes = allOnes && d[i + k] == 0xFF
            }
            return (allOnes ? nil : value, i + len)
        }

        static func video(_ id: String) -> VideoCodec? {
            switch id {
            case "V_VP8": .vp8; case "V_VP9": .vp9; case "V_AV1": .av1; case "V_MPEG4/ISO/AVC": .h264; case "V_MPEGH/ISO/HEVC": .hevc; case "V_THEORA": .theora; default: id
                .hasPrefix("V_") ? .unknown : nil
            }
        }

        static func audio(_ id: String) -> AudioCodec? {
            switch id {
            case "A_VORBIS": .vorbis; case "A_OPUS": .opus; case "A_AAC": .aac; case "A_MPEG/L3": .mp3; case "A_FLAC": .flac; default: id
                .hasPrefix("A_") ? .unknown : nil
            }
        }
    }

    /// ISO BMFF box walker: moov → trak → mdia → minf → stbl → stsd → sample entry four-character codes.
    enum MP4 {
        static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl"]

        static func codecs(in d: Data) -> (video: VideoCodec?, audio: AudioCodec?) {
            var fourccs: [String] = []
            walk(d, d.startIndex, d.endIndex, depth: 0, into: &fourccs)
            let video = fourccs
                .compactMap { (c: String) -> VideoCodec? in
                    switch c { case "avc1", "avc3": .h264; case "hvc1", "hev1": .hevc; case "av01": .av1; case "vp09": .vp9; default: nil }
                }
                .first
            let audio = fourccs
                .compactMap { (c: String) -> AudioCodec? in
                    switch c { case "mp4a": .aac; case "Opus": .opus; case "fLaC": .flac; case ".mp3": .mp3; default: nil }
                }.first
            return (video, audio)
        }

        private static func walk(_ d: Data, _ start: Data.Index, _ end: Data.Index, depth: Int, into out: inout [String]) {
            var i = start
            while i + 8 <= end, depth < 8 {
                var size = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i - d.startIndex, as: UInt32.self) }.bigEndian)
                let type = String(bytes: d[i + 4 ..< i + 8], encoding: .ascii) ?? ""
                var header = 8
                if size == 1, i + 16 <= end {
                    size = Int(d.withUnsafeBytes { $0.loadUnaligned(
                        fromByteOffset: i + 8 - d.startIndex,
                        as: UInt64.self
                    ) }.bigEndian); header = 16
                }
                if size == 0 {
                    size = end - i
                }
                guard size >= header else { return }
                let bodyEnd = min(end, i + size)
                if containers.contains(type) {
                    walk(d, i + header, bodyEnd, depth: depth + 1, into: &out)
                } else if type == "stsd", i + header + 8 <= bodyEnd {
                    var j = i + header + 8 // version/flags + entry count
                    while j + 8 <= bodyEnd, out.count < 8 {
                        let esize = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: j - d.startIndex, as: UInt32.self) }.bigEndian)
                        out.append(String(bytes: d[j + 4 ..< j + 8], encoding: .ascii) ?? "")
                        guard esize >= 8 else { break }
                        j += esize
                    }
                }
                i = bodyEnd
            }
        }
    }
}
