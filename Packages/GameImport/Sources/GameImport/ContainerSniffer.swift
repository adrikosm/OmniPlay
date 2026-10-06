import Foundation
import GameCore

public enum ContainerKind: String, Sendable, Hashable, CaseIterable {
    case folder, zip, sevenZip, rar4, rar5, tar, gzip, xz, zstd, cab, pe, asar, godotPack, unknown
}

/// Identifies the input by bytes, never by extension. Reads at most 64 KiB.
public enum ContainerSniffer {
    public static func identify(_ url: URL) throws -> ContainerKind {
        if try (url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return .folder
        }
        return try identify(header: BoundedReader.readHeader(url: url, bytes: BoundedReader.maxHeader))
    }

    private struct Magic { let offset: Int, bytes: [UInt8], kind: ContainerKind }
    private static let magics: [Magic] = [
        Magic(offset: 0, bytes: [0x50, 0x4B, 0x03, 0x04], kind: .zip), Magic(offset: 0, bytes: [0x50, 0x4B, 0x05, 0x06], kind: .zip),
        Magic(offset: 0, bytes: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], kind: .sevenZip),
        Magic(offset: 0, bytes: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00], kind: .rar5), // before rar4: shares the 7-byte prefix
        Magic(offset: 0, bytes: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00], kind: .rar4),
        Magic(offset: 0, bytes: [0x1F, 0x8B], kind: .gzip), Magic(offset: 0, bytes: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00], kind: .xz), Magic(
            offset: 0,
            bytes: [0x28, 0xB5, 0x2F, 0xFD],
            kind: .zstd
        ),
        Magic(offset: 0, bytes: Array("MSCF".utf8), kind: .cab), Magic(offset: 257, bytes: Array("ustar".utf8), kind: .tar),
        Magic(offset: 0, bytes: Array("GDPC".utf8), kind: .godotPack), // a Godot export's separate .pck
    ]

    public static func identify(header h: Data) -> ContainerKind {
        if let hit = magics.first(where: { matches(h, at: $0.offset, $0.bytes) }) {
            return hit.kind
        }
        if isPE(h) {
            return .pe
        }
        if isASAR(h) {
            return .asar
        }
        return .unknown
    }

    private static func matches(_ h: Data, at offset: Int, _ bytes: [UInt8]) -> Bool {
        h.count >= offset + bytes.count && h[h.startIndex + offset ..< h.startIndex + offset + bytes.count].elementsEqual(bytes)
    }

    /// `MZ` DOS header whose `e_lfanew` (u32 at 0x3C) points at `PE\0\0`.
    private static func isPE(_ h: Data) -> Bool {
        guard matches(h, at: 0, [0x4D, 0x5A]), h.count >= 0x40 else { return false }
        let e = Int(h.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0x3C, as: UInt32.self) }.littleEndian)
        return matches(h, at: e, [0x50, 0x45, 0x00, 0x00])
    }

    /// Electron ASAR: Pickle header (u32 4, u32 header size, u32 string size, u32 json length) then `{"files"`.
    private static func isASAR(_ h: Data) -> Bool {
        guard h.count >= 24 else { return false }
        return h.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }.littleEndian == 4
            && matches(h, at: 16, Array("{\"files\"".utf8))
    }

    /// The first eight bytes as hex, for the `unsupportedContainer` diagnostic.
    public static func firstBytesHex(_ url: URL) -> String {
        ((try? BoundedReader.readHeader(url: url, bytes: 8)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
}
