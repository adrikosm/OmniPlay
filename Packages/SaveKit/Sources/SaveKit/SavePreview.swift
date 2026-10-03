import Foundation
import GameCore

/// What a slot shows in the Save Manager: the game's own name for the save, when it was made, how long was played,
/// who is in the party, and a screenshot when the save carries one. Every read is bounded; anything that does not
/// parse leaves the field empty and the slot keeps its file name.
public struct SavePreview: Sendable, Hashable {
    public var title: String?
    public var savedAt: Date?
    public var playtime: String?
    public var characters: [String] = []
    /// PNG bytes, at most `SavePreviewReader.thumbnailLimit`.
    public var thumbnail: Data?

    public var isEmpty: Bool { title == nil && savedAt == nil && playtime == nil && characters.isEmpty && thumbnail == nil }
}

/// Previews for the files in a slots folder, keyed by file name.
/// - Ren'Py `.save` (a ZIP): `json` (`_save_name`, `_ctime`, `_game_runtime`) and `screenshot.png`, read as single
///   members through the central directory, never the whole archive.
/// - RPG Maker MV/MZ in the web runtime: slots are web-storage keys (`RPG File3`, `rmmzsave.<id>.file3`); the game's
///   global info (`RPG Global`, `rmmzsave.<id>.global`) holds each slot's title, party, playtime and time.
/// - RPG Maker 2000/2003 `SaveNN.lsd`: the title chunk at the start (time, lead hero's name and level).
/// RGSS saves are Ruby Marshal and are never parsed offline; they show their file name and date.
public enum SavePreviewReader {
    public static let thumbnailLimit = 2 << 20
    static let jsonLimit = 256 << 10
    static let globalLimit = 1 << 20

    /// `globals`: other folders where the engine keeps its global info (MV's `RPG Global` lives with the persistent
    /// web storage, not with the slots).
    public static func previews(in slots: URL, globals folders: [URL] = []) -> [String: SavePreview] {
        let files = (try? FileManager.default.contentsOfDirectory(at: slots, includingPropertiesForKeys: nil)) ?? []
        var out: [String: SavePreview] = [:]
        var globals: [String: [Int: SavePreview]] = [:]
        for file in files where !file.lastPathComponent.hasPrefix(".") {
            let name = file.lastPathComponent
            if file.pathExtension.lowercased() == "save" {
                if let preview = renpy(file), !preview.isEmpty {
                    out[name] = preview
                }
            } else if file.pathExtension.lowercased() == "lsd" {
                if let preview = easyRPG(file), !preview.isEmpty {
                    out[name] = preview
                }
            } else if let stem = Optional(file.deletingPathExtension().lastPathComponent),
                      // MV's localStorage keys are stored encoded (`ls.<base64>`); MZ's forage keys keep their names.
                      let key = SaveKey.decodeWebStorage(stem) ?? (stem.hasPrefix("rmmzsave.") ? stem : nil),
                      let (globalKey, slot) = webSlot(key) {
                if globals[globalKey] == nil {
                    let stored = stem.hasPrefix("ls.") ? SaveKey.encodeWebStorage(globalKey) : globalKey
                    let name = stored + (file.pathExtension.isEmpty ? "" : "." + file.pathExtension)
                    let candidates = ([slots] + folders).map { $0.appending(path: name) }
                    let found = candidates.first { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
                    globals[globalKey] = found.map(rpgMakerGlobal) ?? [:]
                }
                if let preview = globals[globalKey]?[slot] {
                    out[name] = preview
                }
            }
        }
        return out
    }

    // MARK: Ren'Py

    static func renpy(_ file: URL) -> SavePreview? {
        guard let zip = BoundedZip(file) else { return nil }
        var preview = SavePreview()
        if let data = zip.member("json", limit: jsonLimit),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            preview.title = (json["_save_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let ctime = json["_ctime"] as? Double {
                preview.savedAt = Date(timeIntervalSince1970: ctime)
            }
            if let runtime = json["_game_runtime"] as? Double, runtime >= 0,
               let seconds = Int(exactly: runtime.rounded(.towardZero)) {
                preview.playtime = clock(seconds)
            }
        }
        preview.thumbnail = zip.member("screenshot.png", limit: thumbnailLimit)
        return preview
    }

    // MARK: RPG Maker 2000/2003

    /// After the `LcfSaveData` header, the first chunk (0x64) is the save's title: 0x01 the time (a Delphi date, days
    /// since 1899-12-30), 0x0B the lead hero's name, 0x0C their level. Chunks are id, size, bytes; ids and sizes are
    /// 7-bit groups, most significant first. Only the first 4 KiB is read.
    static func easyRPG(_ file: URL) -> SavePreview? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let raw = try? handle.read(upToCount: 4096) else { return nil }
        var bytes = [UInt8](raw)[...]
        func number() -> Int? {
            var value = 0
            for _ in 0 ..< 4 {
                guard let byte = bytes.popFirst() else { return nil }
                value = value << 7 | Int(byte & 0x7F)
                if byte & 0x80 == 0 {
                    return value
                }
            }
            return nil
        }
        guard number() == 11, bytes.prefix(11).elementsEqual("LcfSaveData".utf8) else { return nil }
        bytes = bytes.dropFirst(11)
        guard number() == 0x64, let size = number(), size <= bytes.count else { return nil }
        bytes = bytes.prefix(size)
        var preview = SavePreview()
        var name: String?
        var level: Int?
        while let id = number(), id != 0, let length = number(), length <= bytes.count {
            let field = Data(bytes.prefix(length))
            bytes = bytes.dropFirst(length)
            switch id {
            case 0x01 where length == 8:
                let days = Double(bitPattern: field.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) })
                if days.isFinite, days > 1 {
                    preview.savedAt = Date(timeIntervalSince1970: (days - 25569) * 86400)
                }
            case 0x0B:
                // The game's own encoding: UTF-8 in EasyRPG-made saves, Shift-JIS or 1252 in the original engines'.
                name = String(data: field, encoding: .utf8) ?? String(data: field, encoding: .shiftJIS)
                    ?? String(data: field, encoding: .windowsCP1252)
            case 0x0C where (1 ... 4).contains(length):
                level = field.reduce(0) { $0 << 7 | Int($1 & 0x7F) }
            default:
                break
            }
        }
        if let name, !name.isEmpty {
            preview.characters = [name]
            preview.title = level.map { "\(name) · Lv \($0)" } ?? name
        }
        return preview
    }

    // MARK: RPG Maker MV/MZ

    /// The global-info key and slot number for an MV or MZ slot key.
    static func webSlot(_ key: String) -> (String, Int)? {
        if key.hasPrefix("RPG File"), let n = Int(key.dropFirst("RPG File".count)) {
            return ("RPG Global", n)
        }
        if key.hasPrefix("rmmzsave."), let range = key.range(of: ".file", options: .backwards),
           let n = Int(key[range.upperBound...]) {
            return (String(key[..<range.lowerBound]) + ".global", n)
        }
        return nil
    }

    /// MV: LZString base64 text. MZ: zlib, stored as bytes or as a binary string.
    static func rpgMakerGlobal(_ file: URL) -> [Int: SavePreview] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [:] }
        defer { try? handle.close() }
        guard let raw = try? handle.read(upToCount: globalLimit), !raw.isEmpty else { return [:] }
        var json: Data?
        if raw.first == 0x78 {
            json = BoundedDecode.inflate(raw, zlibHeader: true, limit: globalLimit)
        } else if let text = String(data: raw, encoding: .utf8) {
            if text.hasPrefix("x"), let bytes = text.data(using: .isoLatin1) {
                json = BoundedDecode.inflate(bytes, zlibHeader: true, limit: globalLimit)
            } else {
                json = BoundedDecode.lzStringBase64(text, limit: globalLimit).map { Data($0.utf8) }
            }
        }
        guard let json, let list = (try? JSONSerialization.jsonObject(with: json)) as? [Any] else { return [:] }
        var out: [Int: SavePreview] = [:]
        for (slot, item) in list.enumerated() {
            guard let info = item as? [String: Any] else { continue }
            var preview = SavePreview()
            preview.title = info["title"] as? String
            preview.playtime = info["playtime"] as? String
            if let ms = info["timestamp"] as? Double {
                preview.savedAt = Date(timeIntervalSince1970: ms / 1000)
            }
            preview.characters = (info["characters"] as? [[Any]] ?? []).compactMap { $0.first as? String }
            out[slot] = preview
        }
        return out
    }

    static func clock(_ seconds: Int) -> String {
        "\(seconds / 3600):" + String(format: "%02d:%02d", seconds / 60 % 60, seconds % 60)
    }
}

/// Just enough ZIP to take one member out of a Ren'Py save: the end record, the central directory (bounded), and the
/// member's local header. Stored and deflated members only; sizes are checked against the file and the caller's limit.
struct BoundedZip {
    private let handle: FileHandle
    private let size: UInt64
    private struct Entry {
        let offset: UInt64
        let method: UInt16
        let compressed: Int
        let uncompressed: Int
    }

    private var entries: [String: Entry] = [:]
    static let directoryLimit = 1 << 20

    init?(_ url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url), let size = try? handle.seekToEnd(), size >= 22 else { return nil }
        self.handle = handle
        self.size = size
        // The end record sits in the last 22 bytes plus a comment of up to 64 KiB.
        let tail = min(size, 22 + 0xFFFF)
        guard (try? handle.seek(toOffset: size - tail)) != nil, let end = try? handle.read(upToCount: Int(tail)) else { return nil }
        let bytes = [UInt8](end)
        guard let eocd = stride(from: bytes.count - 22, through: 0, by: -1).first(where: {
            bytes[$0] == 0x50 && bytes[$0 + 1] == 0x4B && bytes[$0 + 2] == 0x05 && bytes[$0 + 3] == 0x06
        }) else { return nil }
        let count = Int(Self.u16(bytes, eocd + 10)), dirSize = Int(Self.u32(bytes, eocd + 12)), dirOffset = UInt64(Self.u32(
            bytes,
            eocd + 16
        ))
        guard dirSize <= Self.directoryLimit, dirOffset + UInt64(dirSize) <= size,
              (try? handle.seek(toOffset: dirOffset)) != nil, let dirData = try? handle.read(upToCount: dirSize) else { return nil }
        let dir = [UInt8](dirData)
        var i = 0
        for _ in 0 ..< count {
            guard i + 46 <= dir.count, Self.u32(dir, i) == 0x0201_4B50 else { break }
            let method = Self.u16(dir, i + 10)
            let compressed = Int(Self.u32(dir, i + 20)), uncompressed = Int(Self.u32(dir, i + 24))
            let nameLength = Int(Self.u16(dir, i + 28)), extra = Int(Self.u16(dir, i + 30)), comment = Int(Self.u16(dir, i + 32))
            let local = UInt64(Self.u32(dir, i + 42))
            guard i + 46 + nameLength <= dir.count else { break }
            if let name = String(bytes: dir[(i + 46) ..< (i + 46 + nameLength)], encoding: .utf8) {
                entries[name] = Entry(offset: local, method: method, compressed: compressed, uncompressed: uncompressed)
            }
            i += 46 + nameLength + extra + comment
        }
    }

    func member(_ name: String, limit: Int) -> Data? {
        guard let entry = entries[name], entry.uncompressed <= limit, entry.compressed <= limit,
              entry.offset + 30 <= size, (try? handle.seek(toOffset: entry.offset)) != nil,
              let header = try? handle.read(upToCount: 30), header.count == 30 else { return nil }
        let h = [UInt8](header)
        guard Self.u32(h, 0) == 0x0403_4B50 else { return nil }
        let start = entry.offset + 30 + UInt64(Self.u16(h, 26)) + UInt64(Self.u16(h, 28))
        guard start + UInt64(entry.compressed) <= size, (try? handle.seek(toOffset: start)) != nil,
              let body = try? handle.read(upToCount: entry.compressed), body.count == entry.compressed else { return nil }
        switch entry.method {
        case 0: return body
        case 8: return BoundedDecode.inflate(body, zlibHeader: false, limit: limit)
        default: return nil
        }
    }

    static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(u16(b, i)) | UInt32(u16(b, i + 2)) << 16 }
}

/// Names for a copy of a slot: the next free number in the engine's own pattern, or the next free slot on the same
/// Ren'Py page (`<page>-<slot>-LT1.save`). Nil when the engine has no numbered slots.
public enum SlotNaming {
    /// The first free slot under the name the engine's own Load screen reads (XP and VX show four files, VX Ace
    /// sixteen, Ren'Py pages of at least four); nil when every one is used or the engine's slots are not files OmniPlay names.
    public static func fresh(for engine: EngineFamily, existing: Set<String>) -> String? {
        let used = Set(existing.map { $0.lowercased() })
        let names: [String] = switch engine {
        case .rpgMakerXP: (1 ... 4).map { "Save\($0).rxdata" }
        case .rpgMakerVX: (1 ... 4).map { "Save\($0).rvdata" }
        case .rpgMakerVXAce: (1 ... 16).map { String(format: "Save%02d.rvdata2", $0) }
        // Four per page: the first four slots of a page are visible in both the stock 3×2 grid and 2×2 layouts.
        case .renpy: (0 ..< 60).map { "\($0 / 4 + 1)-\($0 % 4 + 1)-LT1.save" }
        default: []
        }
        return names.first { !used.contains($0.lowercased()) }
    }

    public static func duplicateName(for fileName: String, existing: Set<String>, pattern: String?) -> String? {
        if let match = fileName.wholeMatch(of: /(\d+)-(\d+)-(.+\.save)/), let page = Int(match.1), let slot = Int(match.2) {
            guard slot <= Int.max - 200 else { return nil }
            return (slot + 1 ... slot + 200).lazy.map { "\(page)-\($0)-\(match.3)" }.first { !existing.contains($0) }
        }
        guard let pattern = pattern.flatMap(SlotPattern.init), let index = pattern.index(of: fileName),
              index <= Int.max - 200 else { return nil }
        return (index + 1 ... index + 200).lazy.map(pattern.name(index:)).first { !existing.contains($0) }
    }
}

/// Which files in a slots folder are save slots. The engines keep other data beside them that is not a save and must
/// not be listed, duplicated or deleted as one: Ren'Py's `persistent`, RPG Maker MV's `RPG Global`/`RPG Config` and
/// MZ's `rmmzsave.<id>.global`/`.config` keys (the global one lists the slots; losing it hides every save).
public enum SaveSlots {
    public static func isSlot(_ fileName: String) -> Bool {
        let stem = (fileName as NSString).deletingPathExtension
        if stem == "persistent" || fileName == "persistent" {
            return false
        }
        let key = SaveKey.decodeWebStorage(stem) ?? stem
        return !isSaveList(fileName) && key != "RPG Config" && !(key.hasPrefix("rmmzsave.") && key.hasSuffix(".config"))
    }

    /// MV's `RPG Global` or MZ's `rmmzsave.<id>.global`: the engine's index of its slots, not a slot and not a setting.
    public static func isSaveList(_ fileName: String) -> Bool {
        let stem = (fileName as NSString).deletingPathExtension
        let key = SaveKey.decodeWebStorage(stem) ?? stem
        return key == "RPG Global" || key.hasPrefix("rmmzsave.") && key.hasSuffix(".global")
    }
}
