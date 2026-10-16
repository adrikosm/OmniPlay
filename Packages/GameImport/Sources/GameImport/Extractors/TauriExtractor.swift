import Compression
import Foundation
import GameCore

/// Tauri: a Rust program whose web frontend is compiled in. tauri-codegen keeps every file as a brotli blob in one
/// array of (path, bytes) slices in the read-only data. The array is found from its `/index.html` entry and walked
/// both ways while entries stay well formed. Every slice is the file's claim: each must lie inside the file, and every
/// path goes through the same validator as archive entries.
public struct TauriExtractor: Sendable {
    public static let chunk = 1 << 20
    public let limits: SafetyLimits

    public init(limits: SafetyLimits = .default) { self.limits = limits }

    struct Entry: Equatable {
        let path: String
        let body: Range<Int>
    }

    /// Unpacks the frontend embedded in `url` into `destination`, leaving files already there alone. Nil when `url` is
    /// not a Tauri program.
    public func extract(_ url: URL, to destination: URL) throws -> RunningTotals? {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard let entries = Self.entries(in: data, limit: limits.maxEntries + 1) else { return nil }
        let validator = EntryValidator(limits: limits)
        let sourceBytes = Int64(data.count)
        var totals = RunningTotals()
        // Release builds compress every file; a build without the compression feature stores them as they are.
        let brotli = entries.first { $0.path == "/index.html" }.map { Self.isBrotli(data[$0.body]) } ?? true
        for entry in entries {
            try Task.checkCancellation()
            let decision = validator.validate(ArchiveEntryHeader(path: String(entry.path.dropFirst())), running: &totals)
            switch decision {
            case let .reject(v): throw v
            case .skip: continue
            case let .extract(rel):
                let target = destination.appending(path: rel)
                guard !FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else {
                    totals.skipped += 1
                    continue
                }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = FileManager.default.createFile(atPath: target.path(percentEncoded: false), contents: nil)
                let writer = try FileHandle(forWritingTo: target)
                defer { try? writer.close() }
                // Checked after every slice: a few bytes of brotli can claim gigabytes.
                let write = { (piece: Data) in
                    try writer.write(contentsOf: piece)
                    totals.writtenBytes += Int64(piece.count)
                    if let v = validator.checkWritten(totals, sourceBytes: sourceBytes) {
                        throw v
                    }
                }
                if brotli {
                    try Self.decode(data[entry.body], write: write)
                } else {
                    for start in stride(from: entry.body.lowerBound, to: entry.body.upperBound, by: Self.chunk) {
                        try write(data[start ..< min(start + Self.chunk, entry.body.upperBound)])
                    }
                }
            }
        }
        return totals
    }

    /// The embedded files, in table order; nil when there is no table. Stops one past `limit`, so the validator refuses
    /// the count.
    static func entries(in data: Data, limit: Int) -> [Entry]? {
        data.withUnsafeBytes { raw -> [Entry]? in
            guard let image = Image(raw) else { return nil }
            let word = image.wordSize, stride = 4 * word
            func entry(at offset: Int) -> Entry? {
                guard offset >= 0, offset + stride <= raw.count,
                      let key = image.slice(raw, pointer: image.word(raw, offset), length: image.word(raw, offset + word)),
                      !key.isEmpty, key.count <= 1024, raw[key.lowerBound] == UInt8(ascii: "/"),
                      let body = image.slice(raw, pointer: image.word(raw, offset + 2 * word), length: image.word(raw, offset + 3 * word)),
                      let path = String(bytes: UnsafeRawBufferPointer(rebasing: raw[key]), encoding: .utf8)
                else { return nil }
                return Entry(path: path, body: body)
            }
            // `/index.html` also turns up in scripts; the table's copy is the one a (pointer, 11) pair points at.
            let index = Array("/index.html".utf8)
            var from = 0
            while let hit = find(index, in: raw, from: from) {
                from = hit + 1
                guard let va = image.address(ofOffset: hit) else { continue }
                var needle = [UInt8]()
                for value in [va, UInt64(index.count)] {
                    for byte in 0 ..< word {
                        needle.append(UInt8(truncatingIfNeeded: value >> (8 * UInt64(byte))))
                    }
                }
                guard let found = find(needle, in: raw, from: 0), entry(at: found) != nil else { continue }
                var first = found
                while found - first < limit * stride, entry(at: first - stride) != nil {
                    first -= stride
                }
                var out: [Entry] = []
                var at = first
                while out.count < limit, let next = entry(at: at) {
                    out.append(next)
                    at += stride
                }
                return out
            }
            return nil
        }
    }

    static func find(_ needle: [UInt8], in raw: UnsafeRawBufferPointer, from: Int) -> Int? {
        guard let base = raw.baseAddress, from < raw.count else { return nil }
        return needle.withUnsafeBytes { n in
            memmem(base + from, raw.count - from, n.baseAddress, n.count).map { base.distance(to: UnsafeRawPointer($0)) }
        }
    }

    /// The first slice decodes; the rest of a body is only ever read under `extract`'s limits.
    static func isBrotli(_ body: Data) -> Bool {
        struct Enough: Error {}
        do { try decode(body) { _ in throw Enough() } } catch is Enough {} catch { return false }
        return true
    }

    /// Streams the brotli body out in slices, so a bomb is stopped by `write` before it is held in memory.
    static func decode(_ body: Data, write: (Data) throws -> Void) throws {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_BROTLI) == COMPRESSION_STATUS_OK else {
            throw ImportFailure.unsupportedContainer(firstBytesHex: "tauri: no brotli decoder")
        }
        defer { compression_stream_destroy(stream) }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        try body.withUnsafeBytes { src in
            stream.pointee.src_ptr = src.baseAddress.map { UnsafePointer($0.assumingMemoryBound(to: UInt8.self)) } ?? UnsafePointer(buffer)
            stream.pointee.src_size = src.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.pointee.dst_size
                guard status != COMPRESSION_STATUS_ERROR, status == COMPRESSION_STATUS_END || produced > 0 else {
                    throw ImportFailure.unsupportedContainer(firstBytesHex: "tauri: damaged brotli body")
                }
                try write(Data(bytes: buffer, count: produced))
                if status == COMPRESSION_STATUS_END {
                    return
                }
            }
        }
    }

    /// The PE fields that map an address in the image to a place in the file.
    struct Image {
        let wordSize: Int
        let base: UInt64
        let sections: [PESection]

        init?(_ raw: UnsafeRawBufferPointer) {
            func read(_ offset: Int, _ bytes: Int) -> UInt64? {
                guard offset >= 0, offset + bytes <= raw.count else { return nil }
                return (0 ..< bytes).reduce(UInt64(0)) { $0 | UInt64(raw[offset + $1]) << (8 * UInt64($1)) }
            }
            guard read(0, 2) == 0x5A4D, let e = read(0x3C, 4).map(Int.init), read(e, 4) == 0x4550,
                  let count = read(e + 6, 2), let optional = read(e + 20, 2).map(Int.init) else { return nil }
            switch read(e + 24, 2) {
            case 0x20B: wordSize = 8; base = read(e + 48, 8) ?? 0
            case 0x10B: wordSize = 4; base = read(e + 52, 4) ?? 0
            default: return nil
            }
            sections = (0 ..< Int(min(count, 96))).compactMap { i in
                let s = e + 24 + optional + i * 40
                guard let virtualSize = read(s + 8, 4), let address = read(s + 12, 4), let rawSize = read(s + 16, 4),
                      let offset = read(s + 20, 4) else { return nil }
                return PESection(address: address, size: virtualSize == 0 ? rawSize : min(virtualSize, rawSize), offset: offset)
            }
        }

        func word(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt64 {
            (0 ..< wordSize).reduce(UInt64(0)) { $0 | UInt64(raw[offset + $1]) << (8 * UInt64($1)) }
        }

        /// The file range `length` bytes at image address `pointer`, when all of it lies inside one section and the file.
        func slice(_ raw: UnsafeRawBufferPointer, pointer: UInt64, length: UInt64) -> Range<Int>? {
            for s in sections {
                let (start, overflow) = base.addingReportingOverflow(s.address)
                guard !overflow, pointer >= start, length <= s.size, pointer - start <= s.size - length else { continue }
                let offset = s.offset + (pointer - start)
                guard offset + length <= UInt64(raw.count) else { return nil }
                return Int(offset) ..< Int(offset + length)
            }
            return nil
        }

        func address(ofOffset offset: Int) -> UInt64? {
            let o = UInt64(offset)
            return sections.first { o >= $0.offset && o - $0.offset < $0.size }.map { base &+ $0.address &+ (o - $0.offset) }
        }
    }
}

/// One section of a PE image: where it sits in the image and in the file, and how much of it the file holds.
struct PESection {
    let address: UInt64
    let size: UInt64
    let offset: UInt64
}
