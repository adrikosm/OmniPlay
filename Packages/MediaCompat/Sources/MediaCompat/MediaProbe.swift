import Foundation
import GameCore

/// Media facts that drive per-runtime normalisation. The load-bearing one: WKWebView on iPhone does not play
/// VP9 WebM, so MZ titles with WebM cutscenes need a transcode or an MP4 sibling before first launch.
/// `mpeg4` is MPEG-4 Part 2 in all its forms: Xvid, DivX and Microsoft's MPEG-4 v1-v3.
public enum VideoCodec: String, Codable, Sendable, CaseIterable { case h264, hevc, vp8, vp9, av1, theora, mpeg4, unknown }
public enum AudioCodec: String, Codable, Sendable, CaseIterable { case aac, mp3, vorbis, opus, flac, pcm, unknown }
public enum MediaContainer: String, Codable, Sendable, CaseIterable { case mp4, webm, ogg, ogv, m4a, wav, mp3, midi, avi, unknown }

public struct MediaProbeResult: Codable, Sendable, Hashable {
    /// Relative path inside the game tree.
    public let path: String
    public let container: MediaContainer
    public let video: VideoCodec?
    public let audio: AudioCodec?
    public let hasAlpha: Bool
    public var bytes: Int64 = 0
    /// H.264 or HEVC that Apple's decoders refuse all the same: 10-bit, 4:2:2 or 4:4:4 H.264, or HEVC tagged `hev1`
    /// rather than `hvc1`. WebKit plays those black or not at all.
    public var appleIncompatible: Bool?
    /// An image with more than one frame (animated WebP), which some decoders refuse outright.
    public var animated: Bool?

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
        if MediaRules.kind(of: relativePath) == .image {
            // A header is enough, and games ship images by the thousand.
            var result = MediaProbeResult(path: relativePath, container: .unknown, video: nil, audio: nil, bytes: size)
            if let head = try? read(url, offset: 0, count: 32) {
                result.animated = WebP.isAnimated(head) ? true : nil
            }
            return result
        }
        guard let head = try? read(url, offset: 0, count: window) else { return MediaProbeResult(
            path: relativePath,
            container: .unknown,
            video: nil,
            audio: nil,
            bytes: size
        ) }
        var result = identify(head, path: relativePath)
        if result.container == .mp4 || result.container == .m4a, result.video == nil, result.audio == nil, size > Int64(head.count),
           let tail = try? read(url, offset: max(0, size - Int64(window)), count: window),
           let moov = tail.range(of: Data("moov".utf8), options: .backwards), moov.lowerBound - 4 >= tail.startIndex {
            // The window starts inside mdat; boxes can only be walked from the moov header on.
            let codecs = MP4.codecs(in: tail[(moov.lowerBound - 4)...])
            result = MediaProbeResult(
                path: relativePath,
                container: result.container,
                video: codecs.video,
                audio: codecs.audio,
                bytes: size
            )
            result.appleIncompatible = codecs.appleIncompatible ? true : nil
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
            return MediaProbeResult(path: path, container: .webm, video: video, audio: audio, hasAlpha: ids.contains(EBML.alpha))
        }
        if at(4, "ftyp") {
            let brand = String(bytes: d[d.startIndex + 8 ..< min(d.startIndex + 12, d.endIndex)], encoding: .ascii) ?? ""
            let codecs = MP4.codecs(in: d)
            let container: MediaContainer = brand
                .hasPrefix("M4A") || (codecs.video == nil && codecs.audio != nil && path.lowercased().hasSuffix(".m4a")) ? .m4a : .mp4
            var result = MediaProbeResult(path: path, container: container, video: codecs.video, audio: codecs.audio)
            result.appleIncompatible = codecs.appleIncompatible ? true : nil
            return result
        }
        if d.starts(with: "OggS".utf8) {
            let body = d.dropFirst(27)
            let vorbis = body.range(of: Data([0x01] + "vorbis".utf8)) != nil
            let opus = body.range(of: Data("OpusHead".utf8)) != nil
            // Theora's identification header starts with the byte 0x80, which a Swift string would write as C2 80.
            if body.range(of: Data([0x80] + "theora".utf8)) != nil {
                return MediaProbeResult(path: path, container: .ogv, video: .theora, audio: vorbis ? .vorbis : opus ? .opus : nil)
            }
            if vorbis {
                return MediaProbeResult(path: path, container: .ogg, video: nil, audio: .vorbis)
            }
            if opus {
                return MediaProbeResult(path: path, container: .ogg, video: nil, audio: .opus)
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
        if d.starts(with: "RIFF".utf8), at(8, "AVI ") {
            let codecs = AVI.codecs(in: d)
            return MediaProbeResult(path: path, container: .avi, video: codecs.video, audio: codecs.audio)
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
                   codecID: [UInt8] = [0x86], videoSettings: [UInt8] = [0xE0], alphaMode: [UInt8] = [0x53, 0xC0]
        static let containers: Set<[UInt8]> = [segment, tracks, trackEntry, videoSettings]
        /// Stands in the codec list for a video track that declares an alpha channel (VP8/VP9 with AlphaMode 1).
        static let alpha = "#alpha"

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
                } else if id == alphaMode, d[afterSize ..< bodyEnd].contains(where: { $0 != 0 }) {
                    out.append(alpha)
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
            case "V_VP8": .vp8
            case "V_VP9": .vp9
            case "V_AV1": .av1
            case "V_MPEG4/ISO/AVC": .h264
            case "V_MPEGH/ISO/HEVC": .hevc
            case "V_THEORA": .theora
            case "V_MPEG4/ISO/ASP", "V_MPEG4/ISO/SP", "V_MPEG4/MS/V3": .mpeg4
            default: id.hasPrefix("V_") ? .unknown : nil
            }
        }

        static func audio(_ id: String) -> AudioCodec? {
            switch id {
            case "A_VORBIS": .vorbis
            case "A_OPUS": .opus
            case "A_AAC": .aac
            case "A_MPEG/L3": .mp3
            case "A_FLAC": .flac
            default: id.hasPrefix("A_") ? .unknown : nil
            }
        }
    }

    /// ISO BMFF box walker: moov → trak → mdia → minf → stbl → stsd → sample entry four-character codes.
    /// The first video and audio stream of an AVI, from their `strf` headers (BITMAPINFOHEADER compression,
    /// WAVEFORMATEX format tag).
    enum AVI {
        static func codecs(in d: Data) -> (video: VideoCodec?, audio: AudioCodec?) {
            let b = [UInt8](d)
            var video: VideoCodec?
            var audio: AudioCodec?
            var i = 12
            while let strh = find("strh", in: b, from: i), strh + 16 <= b.count {
                let type = String(bytes: b[strh + 8 ..< strh + 12], encoding: .ascii) ?? ""
                guard let strf = find("strf", in: b, from: strh + 8) else { break }
                if type == "vids", video == nil, strf + 28 <= b.count {
                    video = videoCodec(String(bytes: b[strf + 24 ..< strf + 28], encoding: .ascii)?.uppercased() ?? "")
                } else if type == "auds", audio == nil, strf + 10 <= b.count {
                    audio = switch UInt16(b[strf + 8]) | UInt16(b[strf + 9]) << 8 {
                    case 0x0001: .pcm
                    case 0x0050, 0x0055: .mp3
                    case 0x00FF, 0x1600, 0x1610: .aac
                    case 0x566F: .vorbis
                    default: .unknown
                    }
                }
                i = strf + 8
            }
            return (video, audio)
        }

        static func videoCodec(_ fourcc: String) -> VideoCodec {
            switch fourcc {
            case "XVID", "DIVX", "DX50", "FMP4", "MP4V", "3IV2", "M4S2", "DIV3", "DIV4", "DIV5", "MP43", "MP42", "MPG4", "AP41": .mpeg4
            case "H264", "X264", "AVC1": .h264
            case "VP80": .vp8
            case "VP90": .vp9
            default: .unknown // Motion JPEG, uncompressed, Cinepak, Indeo...
            }
        }

        private static func find(_ tag: String, in b: [UInt8], from start: Int) -> Int? {
            let t = Array(tag.utf8)
            var i = max(start, 0)
            while i + 4 <= b.count {
                if b[i] == t[0], b[i + 1] == t[1], b[i + 2] == t[2], b[i + 3] == t[3] {
                    return i
                }
                i += 1
            }
            return nil
        }
    }

    enum WebP {
        /// RIFF....WEBPVP8X with the animation flag (bit 1 of the flags byte after the chunk header).
        static func isAnimated(_ d: Data) -> Bool {
            let b = [UInt8](d.prefix(21))
            return b.count == 21 && b[0 ..< 4].elementsEqual("RIFF".utf8) && b[8 ..< 16].elementsEqual("WEBPVP8X".utf8) && b[20] & 0x02 != 0
        }
    }

    enum MP4 {
        static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl"]
        /// Sample entries that are not video: audio, subtitles, timecode, metadata.
        static let nonVideo: Set<String> = [
            "mp4a", "Opus", "fLaC", ".mp3", "alac", "ac-3", "ec-3", "ac-4", "lpcm", "sowt", "twos", "in24", "in32", "fl32", "fl64",
            "ulaw", "alaw", "ima4", "samr", "sawb", "mha1", "mhm1", "dtsc", "dtsh", "dtsl", "tx3g", "wvtt", "stpp", "c608", "c708",
            "text", "tmcd", "mebx", "rtp ", "hint", "",
        ]
        static let notAudio: Set<String> = ["tx3g", "wvtt", "stpp", "c608", "c708", "text", "tmcd", "mebx", "rtp ", "hint", ""]

        static func codecs(in d: Data) -> MP4Codecs {
            var fourccs: [String] = []
            var profiles: [UInt8] = []
            walk(d, d.startIndex, d.endIndex, depth: 0, into: &fourccs, profiles: &profiles)
            // High 10, High 4:2:2, High 4:4:4 (and its CAVLC intra form): beyond what VideoToolbox decodes.
            let incompatible = fourccs.contains("hev1") || profiles.contains { [110, 122, 244, 44].contains($0) }
            let video = fourccs
                .compactMap { (c: String) -> VideoCodec? in
                    switch c {
                    case "avc1", "avc3": .h264
                    case "hvc1", "hev1": .hevc
                    case "av01": .av1
                    case "vp09": .vp9
                    case "mp4v": .mpeg4
                    // Anything else a video track may carry (ProRes, Motion JPEG, MPEG-4 Part 2...) is still video.
                    case _ where !nonVideo.contains(c): .unknown
                    default: nil
                    }
                }
                .first
            let audio = fourccs
                .compactMap { (c: String) -> AudioCodec? in
                    switch c {
                    case "mp4a": .aac // MP3 in MP4 says mp4a too; the difference is in esds, and both convert alike
                    case "Opus": .opus
                    case "fLaC": .flac
                    case ".mp3": .mp3
                    case "lpcm", "sowt", "twos", "in24", "in32", "fl32", "fl64": .pcm
                    case _ where nonVideo.contains(c) && !notAudio.contains(c): .unknown // ALAC, AC-3, AMR...
                    default: nil
                    }
                }.first
            return MP4Codecs(video: video, audio: audio, appleIncompatible: incompatible)
        }

        private static func walk(
            _ d: Data,
            _ start: Data.Index,
            _ end: Data.Index,
            depth: Int,
            into out: inout [String],
            profiles: inout [UInt8]
        ) {
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
                    walk(d, i + header, bodyEnd, depth: depth + 1, into: &out, profiles: &profiles)
                } else if type == "stsd", i + header + 8 <= bodyEnd {
                    var j = i + header + 8 // version/flags + entry count
                    while j + 8 <= bodyEnd, out.count < 8 {
                        let esize = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: j - d.startIndex, as: UInt32.self) }.bigEndian)
                        let fourcc = String(bytes: d[j + 4 ..< j + 8], encoding: .ascii) ?? ""
                        out.append(fourcc)
                        guard esize >= 8 else { break }
                        // avc1/avc3 carry an avcC box after the 78-byte visual sample entry; byte 1 is the profile.
                        if fourcc == "avc1" || fourcc == "avc3", j + 8 + 78 < min(bodyEnd, j + esize),
                           let avcC = d[(j + 8 + 78) ..< min(bodyEnd, j + esize)].range(of: Data("avcC".utf8)),
                           avcC.upperBound + 1 < min(bodyEnd, j + esize) {
                            profiles.append(d[avcC.upperBound + 1])
                        }
                        j += esize
                    }
                }
                i = bodyEnd
            }
        }
    }
}

/// What the sample descriptions of an MP4 or MOV say about its first video and audio track.
struct MP4Codecs {
    let video: VideoCodec?
    let audio: AudioCodec?
    let appleIncompatible: Bool
}
