import Foundation
import GameCore

/// Enigma Virtual Box: a packer that carries a virtual file system inside the `.enigma1` section of a Windows program.
/// The file table layout follows evbunpack (mos9527, Apache-2.0): an `EVB\0` header, then a pre-order tree of
/// folder and file nodes with UTF-16 names. Table format 3 (EVB 9.x to 11.x) keeps the bodies after the table;
/// format 1 (7.x) puts each body after its node. Bodies are stored, or split into aPLib-compressed chunks.
/// The program is read through a memory map (clean, file-backed pages); output is written per entry and per chunk.
public struct EnigmaVBExtractor: Sendable {
    /// A chunk inflates into memory whole (aPLib copies reach back anywhere in it); none may exceed this.
    public static let maxChunk = 16 << 20
    static let slice = 1 << 20
    public let limits: SafetyLimits

    public init(limits: SafetyLimits = .default) {
        self.limits = limits
    }

    /// Unpacks the virtual files of `url` into `destination`; the table header is searched for from `sectionOffset`.
    public func extract(
        _ url: URL,
        sectionOffset: Int64,
        to destination: URL,
        progress: (@Sendable (Int64, String) -> Void)? = nil
    ) throws -> RunningTotals {
        var table = try Table(data: Data(contentsOf: url, options: .alwaysMapped), sectionOffset: Int(sectionOffset))
        let validator = EntryValidator(limits: limits)
        var totals = RunningTotals()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        func walk(count: Int, prefix: String, depth: Int) throws {
            guard depth <= limits.maxPathComponents else { throw SafetyViolation(rule: .invalidPath, detail: "EVB folders nest too deep") }
            for _ in 0 ..< count {
                try Task.checkCancellation()
                let node = try table.next()
                // evbunpack's rule: a name is one path component; the default folder is the program's own folder.
                guard !node.name.contains("/"), !node.name.contains("\\") else {
                    throw SafetyViolation(rule: .invalidPath, entryPath: node.name, detail: "EVB name holds a separator")
                }
                let name = node.folder && node.name == "%DEFAULT FOLDER%" ? "" : node.name
                let path = [prefix, name].filter { !$0.isEmpty }.joined(separator: "/")
                if node.folder, path.isEmpty {
                    try walk(count: node.count, prefix: "", depth: depth + 1)
                    continue
                }
                let header = ArchiveEntryHeader(
                    path: path,
                    kind: node.folder ? .directory : .file,
                    declaredSize: node.folder ? nil : Int64(node.original),
                    compressedSize: node.folder ? nil : Int64(node.stored)
                )
                switch validator.validate(header, running: &totals) {
                case let .reject(v): throw v
                case .skip: continue
                case let .extract(rel):
                    let target = destination.appending(path: rel)
                    if node.folder {
                        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                        try walk(count: node.count, prefix: path, depth: depth + 1)
                        continue
                    }
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    // Last wins, as in the packer: the earlier copy's bytes leave the totals the audit checks.
                    if let old = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        totals.declaredBytes -= Int64(old)
                        totals.writtenBytes -= Int64(old)
                    }
                    let written = try table.write(node, to: target)
                    guard written == node.original else {
                        throw SafetyViolation(
                            rule: .sizeMismatch,
                            entryPath: path,
                            detail: "EVB entry gave \(written) of \(node.original) bytes"
                        )
                    }
                    totals.writtenBytes += Int64(written)
                    if let v = validator.checkWritten(totals, sourceBytes: Int64(table.data.count)) {
                        throw v
                    }
                    progress?(totals.writtenBytes, rel)
                }
            }
        }
        try walk(count: table.rootCount, prefix: "", depth: 0)
        return totals
    }

    struct Node { var name = "", folder = false, count = 0, offset = 0, original = 0, stored = 0 }

    /// A cursor over the mapped program; every read is bounds-checked against the file.
    struct Table {
        let data: Data
        let legacy: Bool
        var rootCount = 0
        var cursor = 0
        /// Format 3: where the next file body starts (bodies follow the table in node order).
        var body = 0

        init(data: Data, sectionOffset: Int) throws {
            self.data = data
            let start = min(max(sectionOffset, 0), data.count)
            guard let magic = data[start ..< min(start + Self.searchWindow, data.count)].firstRange(of: Data("EVB\0".utf8))?.lowerBound
            else { throw ImportFailure.unsupportedContainer(firstBytesHex: "EVB: no file table in the .enigma1 section") }
            let format = try Self.u32(data, magic + 20)
            guard format == 1 || format == 3 else {
                throw ImportFailure.unsupportedContainer(firstBytesHex: "EVB table format \(format) is not supported (known: 1 and 3)")
            }
            legacy = format == 1
            if legacy {
                // The first node is the unnamed root (type 0); its size skips to the first child.
                cursor = magic + 64
                let root = try next()
                rootCount = root.count
            } else {
                rootCount = try Self.u32(data, magic + 76)
                body = try magic + 80 + Self.u32(data, magic + 64) - 12
                cursor = magic + 79
            }
        }

        static let searchWindow = 1 << 20

        static func u32(_ d: Data, _ o: Int) throws -> Int {
            guard o >= 0, o + 4 <= d.count else { throw truncated }
            return Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }.littleEndian)
        }

        static let truncated = ImportFailure.unsupportedContainer(firstBytesHex: "EVB: the file table is truncated or damaged")

        /// One node: `u32 size, 8 bytes, u32 count`, a NUL-terminated UTF-16LE name, a type byte, then the type's fields.
        /// The cursor only moves forward, so a hostile table costs at most one node per 17 bytes of the file.
        mutating func next() throws -> Node {
            let start = cursor
            let size = try Self.u32(data, start)
            var n = try Node(count: Self.u32(data, start + 12))
            var p = start + 16
            var units: [UInt16] = []
            while true {
                guard p + 2 <= data.count else { throw Self.truncated }
                let unit = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: p, as: UInt16.self) }.littleEndian
                p += 2
                if unit == 0 {
                    break
                }
                units.append(unit)
                guard units.count <= 1024 else { throw SafetyViolation(rule: .invalidPath, detail: "EVB name longer than 1024 units") }
            }
            n.name = String(decoding: units, as: UTF16.self)
            guard p < data.count else { throw Self.truncated }
            let type = data[p]
            p += 1
            switch (type, legacy) {
            case (2, false):
                n.original = try Self.u32(data, p + 2)
                n.stored = try Self.u32(data, p + 49)
                cursor = p + 53
                n.offset = body
                body += n.stored
            case (2, true):
                let fields = start + size + 4 - 49
                guard fields >= p else { throw Self.truncated }
                n.original = try Self.u32(data, fields + 2)
                n.stored = try Self.u32(data, fields + 41)
                n.offset = fields + 49
                cursor = n.offset + n.stored
            case (3, false):
                n.folder = true
                cursor = p + 25
            case (3, true), (0, true):
                guard start + size + 4 >= p else { throw Self.truncated }
                n.folder = true
                cursor = start + size + 4
            default: throw ImportFailure.unsupportedContainer(firstBytesHex: "EVB: node type \(type) is not a file or folder")
            }
            guard n.offset + n.stored <= data.count else { throw Self.truncated }
            return n
        }

        /// Writes one body; stored when the sizes match, otherwise a chunk table followed by aPLib chunks.
        func write(_ n: Node, to target: URL) throws -> Int {
            _ = FileManager.default.createFile(atPath: target.path(percentEncoded: false), contents: nil)
            let out = try FileHandle(forWritingTo: target)
            defer { try? out.close() }
            let end = n.offset + n.stored
            guard n.original != n.stored else {
                for at in stride(from: n.offset, to: end, by: EnigmaVBExtractor.slice) {
                    try out.write(contentsOf: data[at ..< min(at + EnigmaVBExtractor.slice, end)])
                }
                return n.stored
            }
            // Chunk table: `u32 size, u32`, then 12-byte rows whose first word is a chunk's packed size.
            let tableSize = try Self.u32(data, n.offset)
            guard tableSize >= 8, tableSize <= n.stored else { throw Self.truncated }
            var row = n.offset + 8, at = n.offset + tableSize, written = 0
            while at < end {
                try Task.checkCancellation()
                guard row + 4 <= n.offset + tableSize else { throw Self.truncated }
                let packed = try min(Self.u32(data, row), end - at)
                guard packed > 0 else { throw Self.truncated }
                let chunk = try data[at ..< at + packed].withUnsafeBytes {
                    try APLib.depack($0, limit: min(EnigmaVBExtractor.maxChunk, n.original - written))
                }
                try out.write(contentsOf: chunk)
                written += chunk.count
                row += 12
                at += packed
            }
            return written
        }
    }
}

/// aPLib depacker, written from the published format (Jibz, ibsensoftware.com): a first literal byte, then
/// MSB-first tag bits choose a literal (0), a gamma-coded match (10), a short match (110, offset 0 ends) or a
/// 4-bit near byte (111). Output is capped at `limit`; running out of input ends the stream, and the caller checks
/// the size it was promised.
enum APLib {
    static let damaged = ImportFailure.unsupportedContainer(firstBytesHex: "aPLib: a damaged or oversized chunk")

    static func depack(_ src: UnsafeRawBufferPointer, limit: Int) throws -> [UInt8] {
        var raw = src
        // An `AP32` header (u32 header size, u32 packed size, ...) wraps some streams.
        if raw.count >= 24, raw.prefix(4).elementsEqual("AP32".utf8) {
            let header = Int(raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian)
            let packed = Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian)
            guard header <= raw.count else { throw damaged }
            raw = UnsafeRawBufferPointer(rebasing: raw[header ..< header + min(packed, raw.count - header)])
        }
        let s = raw
        struct End: Error {}
        var out: [UInt8] = []
        var i = 0, tag = 0, bits = 0, r0 = 0, lwm = false
        func byte() throws -> Int {
            guard i < s.count else { throw End() }
            i += 1
            return Int(s[i - 1])
        }
        func bit() throws -> Int {
            if bits == 0 {
                tag = try byte()
                bits = 8
            }
            bits -= 1
            return (tag >> bits) & 1
        }
        func gamma() throws -> Int {
            var v = 1
            repeat {
                v = try (v << 1) + bit()
                guard v <= limit + 0xFFFF else { throw damaged }
            } while try bit() == 1
            return v
        }
        func put(_ b: UInt8) throws {
            guard out.count < limit else { throw damaged }
            out.append(b)
        }
        func copy(_ offset: Int, _ length: Int) throws {
            guard offset > 0, offset <= out.count, length <= limit - out.count else { throw damaged }
            for _ in 0 ..< length {
                out.append(out[out.count - offset])
            }
        }
        do {
            try put(UInt8(byte()))
            while true {
                // The opcode is the run of leading 1 bits: 0, 10, 110 or 111.
                var ones = 0
                while ones < 3, try bit() == 1 {
                    ones += 1
                }
                switch ones {
                case 0:
                    try put(UInt8(byte()))
                    lwm = false
                case 1:
                    var offset = try gamma()
                    if !lwm, offset == 2 {
                        try copy(r0, gamma())
                    } else {
                        offset = try ((offset - (lwm ? 2 : 3)) << 8) + byte()
                        let extra = (offset >= 32000 ? 1 : 0) + (offset >= 1280 ? 1 : 0) + (offset < 128 ? 2 : 0)
                        try copy(offset, gamma() + extra)
                        r0 = offset
                    }
                    lwm = true
                case 2:
                    let b = try byte()
                    if b >> 1 == 0 {
                        return out
                    }
                    try copy(b >> 1, 2 + (b & 1))
                    r0 = b >> 1
                    lwm = true
                default:
                    var offset = 0
                    for _ in 0 ..< 4 {
                        offset = try (offset << 1) + bit()
                    }
                    if offset == 0 {
                        try put(0)
                    } else {
                        try copy(offset, 1)
                    }
                    lwm = false
                }
            }
        } catch is End {}
        return out
    }
}
