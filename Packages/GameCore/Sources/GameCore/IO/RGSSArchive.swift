import Foundation

/// RPG Maker's encrypted game archives (`Game.rgssad`, `.rgss2a`, `.rgss3a`), checked before an engine sees them.
///
/// mkxp-z parses the archive inside our process and trusts the lengths it finds there: every entry name goes into
/// a fixed 512-byte buffer, and a name length read from a truncated or damaged file runs straight past it into
/// memory SDL owns. The corruption surfaces much later somewhere unrelated, so the only useful place to stop a bad
/// archive is before the engine mounts it. This walks the entry table the way the engine does, against the real
/// file length, reading only the table (a few bytes per entry), never the payload.
public enum RGSSArchive {
    /// The engine's name buffer is 512 bytes and it writes a terminator after the name.
    public static let maxNameLength: UInt32 = 511
    /// More entries than any real game ships; a walk this long means the table is garbage.
    public static let maxEntries = 1_000_000

    public struct Invalid: Error, Equatable, Sendable, CustomStringConvertible {
        public let file: String
        public let reason: String

        public var description: String {
            "\(file) is damaged (\(reason)). It may be an incomplete copy or download; import the game again."
        }
    }

    /// The archive extensions mkxp-z mounts from the game folder, one per RGSS generation.
    public static let extensions: Set<String> = ["rgssad", "rgss2a", "rgss3a"]

    /// Checks every archive at the top of `folder`; throws on the first damaged one.
    public static func validateArchives(in folder: URL) throws {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in items where extensions.contains(url.pathExtension.lowercased()) {
            _ = try validate(url)
        }
    }

    /// Returns the number of entries in a well-formed archive.
    @discardableResult
    public static func validate(_ url: URL) throws -> Int {
        let name = url.lastPathComponent
        func invalid(_ reason: String) -> Invalid { Invalid(file: name, reason: reason) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw invalid("it cannot be read") }
        defer { try? handle.close() }
        let length = try UInt64(url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)

        func read(_ count: Int, at offset: UInt64) throws -> Data {
            guard offset + UInt64(count) <= length else { throw invalid("an entry runs past the end of the file") }
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count), data.count == count else {
                throw invalid("an entry runs past the end of the file")
            }
            return data
        }
        func word(at offset: UInt64) throws -> UInt32 {
            try read(4, at: offset).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        }

        let header = try read(8, at: 0)
        guard header.prefix(7) == Data("RGSSAD\0".utf8) else { throw invalid("it has no RGSSAD header") }
        switch header[7] {
        case 1: return try walkVersion1(length: length, word: word, invalid: invalid)
        case 3: return try walkVersion3(length: length, word: word, invalid: invalid)
        default: throw invalid("unknown archive version \(header[7])")
        }
    }

    /// XP and VX: entries follow each other, each `name length, name, size, data`, all XORed with a key stream
    /// that advances once per field and once per name byte. The engine reads until fewer than four bytes remain.
    private static func walkVersion1(
        length: UInt64,
        word: (UInt64) throws -> UInt32,
        invalid: (String) -> Invalid
    ) throws -> Int {
        var key: UInt32 = 0xDEAD_CAFE
        func advance() -> UInt32 {
            let old = key
            key = key &* 7 &+ 3
            return old
        }
        var offset: UInt64 = 8
        var entries = 0
        while length - offset >= 4 {
            let nameLength = try word(offset) ^ advance()
            guard nameLength <= maxNameLength else { throw invalid("an entry name claims \(nameLength) bytes") }
            // The name bytes only advance the key; their content does not matter here.
            for _ in 0 ..< nameLength {
                _ = advance()
            }
            let size = try word(offset + 4 + UInt64(nameLength)) ^ advance()
            let data = offset + 8 + UInt64(nameLength)
            guard data + UInt64(size) <= length else { throw invalid("an entry runs past the end of the file") }
            offset = data + UInt64(size)
            entries += 1
            guard entries <= maxEntries else { throw invalid("its entry table never ends") }
        }
        return entries
    }

    /// VX Ace: a key seed, then a table of `offset, size, key, name length, name` records XORed with one key,
    /// ended by a zero offset. Payloads live after the table at the offsets it names.
    private static func walkVersion3(
        length: UInt64,
        word: (UInt64) throws -> UInt32,
        invalid: (String) -> Invalid
    ) throws -> Int {
        let key = try word(8) &* 9 &+ 3
        var offset: UInt64 = 12
        var entries = 0
        while true {
            let dataOffset = try word(offset) ^ key
            if dataOffset == 0 {
                return entries
            }
            let size = try word(offset + 4) ^ key
            let nameLength = try word(offset + 12) ^ key
            guard nameLength <= maxNameLength else { throw invalid("an entry name claims \(nameLength) bytes") }
            guard UInt64(dataOffset) + UInt64(size) <= length else { throw invalid("an entry runs past the end of the file") }
            offset += 16 + UInt64(nameLength)
            guard offset <= length else { throw invalid("its entry table runs past the end of the file") }
            entries += 1
            guard entries <= maxEntries else { throw invalid("its entry table never ends") }
        }
    }
}
