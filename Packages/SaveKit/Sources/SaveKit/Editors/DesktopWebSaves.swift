import Foundation
import GameCore

/// RPG Maker MV and MZ saves as the PC editions write them, turned into what OmniPlay's web runtime keeps.
///
/// The PC editions write one file per save beside the game (`file3.rpgsave`, `global.rmmzsave`). In OmniPlay the same
/// games save to web storage, and the web runtime keeps each key as a file (`SaveBridge`): MV under `ls.<base64 of
/// "RPG File3">.rpgsave`, MZ under `rmmzsave.<gameId>.file3.rmmzsave`, slots in `Saves/slots` and the global info in
/// the game's persistent web storage. A PC save copied in under its own name is never asked for; an MV one even stops
/// the game from starting, because the runtime cannot tell which key it belongs to.
///
/// Both engines list their saves from the global info (MV refuses to load a slot it has no entry for), so a slot is
/// imported together with its entry from the PC's `global` file, merged into the game's own global info instead of
/// replacing it: the saves already made in OmniPlay stay listed.
public enum DesktopWebSaves {
    public enum Edition: Sendable, Hashable {
        case mv
        /// `$dataSystem.advanced.gameId`, which MZ puts in every storage key.
        case mz(gameID: String)
    }

    public enum Name: Sendable, Hashable {
        case slot(Int)
        case global
        case config
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notASave(String)
        case noGlobalEntry(String)
        case noFreeSlot

        public var description: String {
            switch self {
            case let .notASave(file): "\(file) is not an RPG Maker save this game can read."
            case let .noGlobalEntry(file): "\(file) is not listed in the global file imported with it."
            case .noFreeSlot: "Every save slot this game shows is taken."
            }
        }
    }

    /// Slots the stock Load screens show; a save moved past them would exist but never be listed.
    public static let visibleSlots = 1 ... 20
    static let globalLimit = 4 << 20

    /// `file3.rpgsave` → `.slot(3)`, `global.rmmzsave` → `.global`, in the edition's own extension; nil otherwise.
    public static func name(of fileName: String, edition: Edition) -> Name? {
        let ext = edition == .mv ? "rpgsave" : "rmmzsave"
        let lower = fileName.lowercased()
        guard lower.hasSuffix("." + ext) else { return nil }
        let stem = lower.dropLast(ext.count + 1)
        switch stem {
        case "global": return .global
        case "config": return .config
        default:
            guard stem.hasPrefix("file"), let n = Int(stem.dropFirst(4)), n >= 0, n < 10000 else { return nil }
            return .slot(n)
        }
    }

    /// The web-storage key the game reads (`RPG File3`, `rmmzsave.<gameId>.file3`).
    public static func key(_ name: Name, edition: Edition) -> String {
        switch (edition, name) {
        case let (.mv, .slot(n)): "RPG File\(n)"
        case (.mv, .global): "RPG Global"
        case (.mv, .config): "RPG Config"
        case let (.mz(id), .slot(n)): "rmmzsave.\(id).file\(n)"
        case let (.mz(id), .global): "rmmzsave.\(id).global"
        case let (.mz(id), .config): "rmmzsave.\(id).config"
        }
    }

    /// Where the web runtime keeps that key, relative to `Saves/`: slots with the slots, everything else with the
    /// game's persistent web storage.
    public static func relativePath(_ name: Name, edition: Edition) -> String {
        let key = key(name, edition: edition)
        switch edition {
        case .mv:
            let file = SaveKey.encodeWebStorage(key) + ".rpgsave"
            if case .slot = name {
                return "slots/\(file)"
            }
            return "persistent/webLocalStorage/\(file)"
        case .mz:
            if case .slot = name {
                return "slots/\(key).rmmzsave"
            }
            return "persistent/webIndexedDB/\(key).rmmzsave"
        }
    }

    /// The slot number in a key the web runtime already stores (`RPG File3` → 3), for finding free slots.
    public static func slotNumber(inKey key: String, edition: Edition) -> Int? {
        let prefix = switch edition {
        case .mv: "RPG File"
        case let .mz(id): "rmmzsave.\(id).file"
        }
        guard key.hasPrefix(prefix) else { return nil }
        return Int(key.dropFirst(prefix.count))
    }

    /// The bytes as the web runtime stores them. MV: the LZString text, unchanged. MZ: raw zlib; the PC edition
    /// writes its zlib data as a "binary string" (one character per byte) that Node saves as UTF-8.
    public static func webBytes(_ data: Data, edition: Edition) -> Data? {
        switch edition {
        case .mv:
            return String(data: data, encoding: .utf8) == nil ? nil : data
        case .mz:
            if data.first == 0x78 {
                return data
            }
            guard let text = String(data: data, encoding: .utf8), text.hasPrefix("x"),
                  let bytes = text.data(using: .isoLatin1) else { return nil }
            return bytes
        }
    }

    /// Global info as a list indexed by slot number (`null` where a slot is empty).
    public static func decodeGlobal(_ web: Data, edition: Edition) -> [Any]? {
        let json: Data? = switch edition {
        case .mv: String(data: web, encoding: .utf8).flatMap { LZString.decompressFromBase64($0, limit: globalLimit) }.map { Data($0.utf8) }
        case .mz: BoundedDecode.inflate(web, zlibHeader: true, limit: globalLimit)
        }
        guard let json, json.count < globalLimit, let object = try? JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed])
        else { return nil }
        // MV's older JsonEx wraps arrays as {"@a": [...]}; plain JSON otherwise.
        if let wrapped = (object as? [String: Any])?["@a"] as? [Any] {
            return wrapped
        }
        return object as? [Any]
    }

    public static func encodeGlobal(_ list: [Any], edition: Edition) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: list, options: [.withoutEscapingSlashes])
        switch edition {
        case .mv:
            guard let text = String(data: json, encoding: .utf8) else { throw Failure.notASave("global") }
            return Data(LZString.compressToBase64(text).utf8)
        case .mz:
            return try RPGMakerSaveDocument.zlib(json)
        }
    }

    /// The game's global info with the imported slots' entries added: `moves` maps a slot number in the PC's global
    /// file to the slot it is imported into. Entries for every other slot stay as the game had them.
    public static func mergeGlobal(existing: [Any]?, incoming: [Any], moves: [Int: Int]) throws -> [Any] {
        var merged = existing ?? []
        for (from, to) in moves {
            guard incoming.indices.contains(from), !(incoming[from] is NSNull) else { throw Failure.noGlobalEntry("file\(from)") }
            while merged.count <= to {
                merged.append(NSNull())
            }
            merged[to] = incoming[from]
        }
        return merged
    }

    /// Where each imported slot goes: its own number when that is free (or when replacing), otherwise the first free
    /// visible slot. The autosave slot (0, MZ) always stays 0.
    public static func placements(incoming: [Int], occupied: Set<Int>, replace: Bool) throws -> [Int: Int] {
        var moves: [Int: Int] = [:]
        var taken = occupied
        // Own numbers first, so a save moved aside never takes a number another imported save keeps.
        for slot in incoming where replace || slot == 0 || !occupied.contains(slot) {
            moves[slot] = slot
            taken.insert(slot)
        }
        for slot in incoming.sorted() where moves[slot] == nil {
            guard let free = visibleSlots.first(where: { !taken.contains($0) }) else { throw Failure.noFreeSlot }
            moves[slot] = free
            taken.insert(free)
        }
        return moves
    }
}
