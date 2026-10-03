import Diagnostics
import Foundation
import GameCore
import GameImport
import OverlayVFS

/// What detectors are allowed to touch: a located game root through a case-insensitive index, bounded reads,
/// and the import sidecars. Nothing here materialises a directory tree.
public final class ScanContext: Sendable {
    public let root: URL
    public let index: PathIndex
    public let sidecars: ImportSidecars
    public let pePayload: PEPayload?
    public static let layer = "scan"

    /// Builds a temporary index of `root` (deleted with `close()`); `pePayload` describes the executable the game came from, if any.
    public init(root: URL, sidecars: ImportSidecars = ImportSidecars(), pePayload: PEPayload? = nil) throws {
        self.root = root
        self.sidecars = sidecars
        self.pePayload = pePayload
        let file = FileManager.default.temporaryDirectory.appending(path: "omniplay-scan-\(UUID().uuidString).sqlite")
        index = try PathIndex.open(at: file)
        try index.build(layer: Self.layer, root: root)
    }

    public func close() {
        try? FileManager.default.removeItem(at: index.url)
    }

    public func entry(_ logical: String) -> IndexedEntry? {
        try? index.lookup(layer: Self.layer, key: PathKey.normalize(logical))
    }

    public func exists(_ logical: String) -> Bool { entry(logical) != nil }

    /// Real URL of a logical path, or nil.
    public func url(_ logical: String) -> URL? { entry(logical).map { root.appending(path: $0.realRel) } }

    public func header(_ logical: String, bytes: Int) -> Data? {
        guard let url = url(logical) else { return nil }
        return try? BoundedReader.readHeader(url: url, bytes: bytes)
    }

    public func smallFile(_ logical: String, max: Int = 2 << 20) -> Data? {
        guard let url = url(logical) else { return nil }
        return try? SmallFileGuard.read(url, maxBytes: max)
    }

    public func text(_ logical: String, max: Int = 2 << 20) -> String? {
        smallFile(logical, max: max).flatMap { String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .isoLatin1) }
    }

    /// An RPG Maker ini: UTF-8, else Shift-JIS when that reads as Japanese (it has kana, or two high bytes in a row as
    /// every kanji-only title has), else Windows-1252. Latin-1 turns a Shift-JIS title into mojibake, and Shift-JIS turns
    /// a Western `Pokémon` (one high byte between letters) into kanji.
    public func iniText(_ logical: String) -> String? {
        guard let data = smallFile(logical, max: 64 << 10) else { return nil }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        let sjis = String(data: data, encoding: .shiftJIS)
        let doubleByte = zip(data, data.dropFirst()).contains { $0 >= 0x80 && $1 >= 0x80 }
        if let sjis, doubleByte
            || sjis.unicodeScalars.contains(where: { (0x3040 ... 0x30FF).contains($0.value) || (0xFF66 ... 0xFF9F).contains($0.value) }) {
            return sjis
        }
        return String(data: data, encoding: .windowsCP1252) ?? sjis ?? String(data: data, encoding: .isoLatin1)
    }

    /// Direct children of a logical directory (sorted by key), at most `limit`.
    public func children(_ logical: String, limit: Int = 512) -> [IndexedEntry] {
        (try? index.children(layer: Self.layer, directoryKey: PathKey.normalize(logical), limit: limit)) ?? []
    }

    /// Entries whose key matches a GLOB pattern (`*`, `?`), lower-case, at most `limit`.
    public func glob(_ pattern: String, limit: Int = 64) -> [IndexedEntry] {
        (try? index.glob(layer: Self.layer, pattern: pattern.lowercased(), limit: limit)) ?? []
    }
}
