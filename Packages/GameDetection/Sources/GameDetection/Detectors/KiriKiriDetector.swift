import Compression
import Foundation
import GameCore

/// KiriKiri 2 / Z games (TJS and KAG): an XP3 archive whose index names `startup.tjs`, or a loose project with
/// `startup.tjs`. An arbitrary XP3 is not enough: patch archives and other engines' data use the format too. They play
/// through the web runtime's KrKr2 engine (Kirikiroid2's core with its plugin replacements).
public struct KiriKiriDetector: Detector {
    public let id = DetectorID.kirikiri
    public let version = 1
    public init() {}

    static let magicBytes: [UInt8] = [0x58, 0x50, 0x33, 0x0D, 0x0A, 0x20, 0x0A, 0x1A, 0x8B, 0x67, 0x01]

    public func probe(_ ctx: ScanContext, facts: StructureFacts) throws -> DetectorReport {
        var r = DetectorReport()
        let archives = ctx.children("", limit: 512).filter { !$0.isDir && $0.key.hasSuffix(".xp3") }
            .filter { ctx.header($0.realRel, bytes: 11).map { Array($0) == Self.magicBytes } ?? false }
        let loose = ctx.exists("startup.tjs") ? "startup.tjs" : ctx.exists("data/startup.tjs") ? "data/startup.tjs" : nil
        guard !archives.isEmpty || loose != nil else { return r }

        // The index is readable even when the file bodies are encrypted (a game-specific filter), so this says where
        // the game starts, not that KrKr2 can read it; the session log shows a filter it does not carry.
        let startupArchive = archives.first { archive in
            guard let url = ctx.url(archive.realRel), let names = Self.index(of: url) else { return false }
            return names.contains { $0.lowercased() == "startup.tjs" }
        }?.realRel
        if startupArchive == nil, loose == nil {
            // XP3 archives without a startup script: patches, or another engine's data.
            r.claimFamily(.kirikiri, 0.6)
            r.unsupported = "These XP3 archives hold no startup.tjs; the game's main archive is missing or encrypted."
            r.add(id, .magic(path: archives[0].realRel, bytes: "XP3"), 0.6, .fileMagic, "XP3 archives without startup.tjs")
            return r
        }
        if let startupArchive {
            r.add(id, .text(path: startupArchive, excerpt: "startup.tjs"), 0.95, .fileContent, "\(startupArchive) holds startup.tjs")
            r.partial.entryPoint = startupArchive
        } else if let loose {
            r.add(id, .present(path: loose), 0.9, .fileName, "loose KiriKiri project (\(loose))")
            r.partial.entryPoint = loose
        }
        r.claimFamily(.kirikiri, 0.95)
        r.partial.exportPlatform = .windows
        r.partial.profileHints["coopCoep"] = "true"
        r.partial.runtimeCandidates = [RuntimeCandidate(runtime: .web, confidence: 0.85, reason: "KrKr2 (KiriKiri 2/Z) in the web runtime")]
        return r
    }

    /// The file names in an XP3 index. Handles the plain header and the 2.28+ layout whose first offset (0x17) points
    /// at a second header holding the real index offset. The index is bounded to 64 MiB compressed.
    static func index(of url: URL) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return nil }
        func u64(_ at: UInt64) -> UInt64? {
            guard at <= fileSize, fileSize - at >= 8, (try? handle.seek(toOffset: at)) != nil,
                  let d = try? handle.read(upToCount: 8), d.count == 8 else { return nil }
            return d.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        }
        guard var offset = u64(11) else { return nil }
        if offset == 0x17 {
            // 0x17: flag byte 0x80, 8 reserved bytes, then the index offset.
            guard let real = u64(0x17 + 1 + 8) else { return nil }
            offset = real
        }
        guard offset <= fileSize, fileSize - offset >= 9,
              (try? handle.seek(toOffset: offset)) != nil, let flag = try? handle.read(upToCount: 1), flag.count == 1 else { return nil }
        var index: Data
        if flag[flag.startIndex] & 0x07 == 1 {
            guard fileSize - offset >= 17, let packed = u64(offset + 1), let size = u64(offset + 9),
                  packed < 64 << 20, size < 256 << 20,
                  (try? handle.seek(toOffset: offset + 17)) != nil, let body = try? handle.read(upToCount: Int(packed)),
                  body.count == Int(packed), let raw = inflate(body, expected: Int(size)) else { return nil }
            index = raw
        } else {
            guard let size = u64(offset + 1), size < 64 << 20, (try? handle.seek(toOffset: offset + 9)) != nil,
                  let raw = try? handle.read(upToCount: Int(size)), raw.count == Int(size) else { return nil }
            index = raw
        }
        return entries(in: index)
    }

    static func entries(in index: Data) -> [String] {
        let bytes = [UInt8](index)
        func u32(_ i: Int) -> UInt32 { UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) <<
            24
        }
        func u64(_ i: Int) -> UInt64 { UInt64(u32(i)) | UInt64(u32(i + 4)) << 32 }
        var out: [String] = []
        var i = 0
        while i + 12 <= bytes.count {
            guard let size = Int(exactly: u64(i + 4)), size <= bytes.count - i - 12 else { break }
            let end = i + 12 + size
            if bytes[i ..< i + 4].elementsEqual("File".utf8) {
                var j = i + 12
                while end - j >= 12 {
                    guard let subSize = Int(exactly: u64(j + 4)), subSize <= end - j - 12 else { break }
                    if bytes[j ..< j + 4].elementsEqual("info".utf8), subSize >= 22 {
                        let length = Int(UInt16(bytes[j + 32]) | UInt16(bytes[j + 33]) << 8)
                        if j + 34 + length * 2 <= j + 12 + subSize {
                            let name = String(decoding: stride(from: j + 34, to: j + 34 + length * 2, by: 2).map {
                                UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8
                            }, as: UTF16.self)
                            out.append(name)
                        }
                    }
                    j += 12 + subSize
                }
            }
            i += 12 + size
        }
        return out
    }

    /// zlib stream (2-byte header, raw deflate, Adler-32 trailer) → bytes, through Apple's raw-deflate decoder.
    static func inflate(_ data: Data, expected: Int) -> Data? {
        guard data.count > 6, expected > 0 else { return nil }
        let deflated = data.subdata(in: data.startIndex + 2 ..< data.endIndex - 4)
        var out = Data(count: expected)
        let written = out.withUnsafeMutableBytes { dst in
            deflated.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, expected,
                    src.bindMemory(to: UInt8.self).baseAddress!, deflated.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        return written == expected ? out : nil
    }
}
