import Foundation
import GameCore

/// What sits inside or after a Windows executable. "Unwrap, don't emulate": NW.js appends a ZIP, Godot appends
/// a PCK, self-extractors prepend a stub. Reads headers and a bounded tail only.
public struct PEPayload: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case none
        case appendedZip(offset: Int64)
        case appendedSevenZip(offset: Int64)
        case appendedRar(offset: Int64)
        case cab(offset: Int64)
        case godotPCK(offset: Int64, size: Int64)
        case enigmaVB
    }

    public enum Machine: UInt16, Sendable { case x86 = 0x014C, x64 = 0x8664, arm64 = 0xAA64, unknown = 0 }

    public let kind: Kind
    public let machine: Machine
}

public enum PEOverlayScanner {
    static let tailWindow = 128 << 10

    /// Nil when the file is not a well-formed PE (callers treat it as a data file).
    public static func scan(_ url: URL) throws -> PEPayload? {
        let size = try Int64((url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let head = try BoundedReader.readHeader(url: url, bytes: 64 << 10)
        guard let pe = parseHeaders(head, fileSize: size) else { return nil }
        let tail = try readTail(url, size: size)
        var kind = PEPayload.Kind.none
        if pe.sectionNames.contains(".enigma1") {
            kind = .enigmaVB
        } else if let godot = godotTail(tail, size: size) {
            kind = godot
        } else if let appended = appendedArchive(url, overlayOffset: pe.overlayOffset, size: size, tail: tail) {
            kind = appended
        }
        return PEPayload(kind: kind, machine: pe.machine)
    }

    struct Headers { let machine: PEPayload.Machine; let overlayOffset: Int64; let sectionNames: [String] }

    static func parseHeaders(_ h: Data, fileSize: Int64) -> Headers? {
        func u16(_ o: Int) -> UInt16? { o + 2 <= h.count ? h.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt16.self) }
            .littleEndian : nil
        }
        func u32(_ o: Int) -> UInt32? { o + 4 <= h.count ? h.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }
            .littleEndian : nil
        }
        guard h.count >= 0x40, h[h.startIndex] == 0x4D, h[h.startIndex + 1] == 0x5A, let e = u32(0x3C).map(Int.init),
              e + 24 <= h.count, u32(e) == 0x0000_4550 else { return nil }
        let machine = PEPayload.Machine(rawValue: u16(e + 4) ?? 0) ?? .unknown
        guard let sections = u16(e + 6), let optSize = u16(e + 20), let sizeOfHeaders = u32(e + 24 + 60) else { return nil }
        let table = e + 24 + Int(optSize)
        var overlay = Int64(sizeOfHeaders)
        var names: [String] = []
        for i in 0 ..< Int(min(sections, 96)) {
            let s = table + i * 40
            guard s + 40 <= h.count, let raw = u32(s + 16), let ptr = u32(s + 20) else { break }
            let name = String(bytes: h[h.startIndex + s ..< h.startIndex + s + 8].prefix { $0 != 0 }, encoding: .ascii) ?? ""
            names.append(name)
            if raw > 0 {
                overlay = max(overlay, Int64(ptr) + Int64(raw))
            }
        }
        guard overlay <= fileSize else { return nil } // truncated image
        return Headers(machine: machine, overlayOffset: overlay, sectionNames: names)
    }

    private static func readTail(_ url: URL, size: Int64) throws -> Data {
        let want = Int(min(Int64(tailWindow), size))
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        try h.seek(toOffset: UInt64(size - Int64(want)))
        return try h.read(upToCount: want) ?? Data()
    }

    /// Godot embeds the PCK after the image and finishes the file with `u64 pck size` + `GDPC`.
    static func godotTail(_ tail: Data, size: Int64) -> PEPayload.Kind? {
        guard tail.count >= 12, tail.suffix(4).elementsEqual("GDPC".utf8) else { return nil }
        let raw = tail.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: tail.count - 12, as: UInt64.self) }.littleEndian
        // The size is the file's claim: `Int64(exactly:)`, since a value past Int64.max would trap a plain conversion.
        guard let pckSize = Int64(exactly: raw) else { return nil }
        let offset = size - 12 - pckSize
        guard pckSize > 0, offset >= 0 else { return nil }
        return .godotPCK(offset: offset, size: pckSize)
    }

    /// Looks at the first 4 KiB of the overlay for an archive signature, then for a ZIP end record in the tail.
    static func appendedArchive(_ url: URL, overlayOffset: Int64, size: Int64, tail: Data) -> PEPayload.Kind? {
        guard overlayOffset < size else { return nil }
        let h = try? FileHandle(forReadingFrom: url)
        defer { try? h?.close() }
        try? h?.seek(toOffset: UInt64(overlayOffset))
        let window = (try? h?.read(upToCount: 4096)) ?? Data()
        let signatures: [([UInt8], (Int64) -> PEPayload.Kind)] = [
            ([0x50, 0x4B, 0x03, 0x04], { .appendedZip(offset: $0) }),
            ([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], { .appendedSevenZip(offset: $0) }),
            ([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07], { .appendedRar(offset: $0) }),
            ([0x4D, 0x53, 0x43, 0x46], { .cab(offset: $0) }),
        ]
        for (sig, make) in signatures {
            if let i = window.firstRange(of: Data(sig))?.lowerBound {
                return make(overlayOffset + Int64(i - window.startIndex))
            }
        }
        // A zip whose local headers start later still ends with an EOCD record in the tail.
        if tail.range(of: Data([0x50, 0x4B, 0x05, 0x06]), options: .backwards) != nil {
            return .appendedZip(offset: overlayOffset)
        }
        return nil
    }
}
