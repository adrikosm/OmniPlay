import Foundation

/// An RPG Maker MV or MZ save decoded to its JSON (JsonEx: plain JSON with `"@"` class tags, kept as they are), for
/// editing while the game is not running. MV: LZString base64 text. MZ: zlib, as raw bytes or as a binary string.
/// Saves over 32 MiB are refused; those are edited in the engine instead.
public final class RPGMakerSaveDocument: @unchecked Sendable {
    public enum Format: Sendable { case mv, mz, mzBinaryString }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case tooLarge(Int)
        case notASave(String)

        public var description: String {
            switch self {
            case let .tooLarge(bytes): "This save is \(bytes >> 20) MB; saves this large are edited in the game instead."
            case let .notASave(reason): "Corrupt or unsupported save: \(reason)"
            }
        }
    }

    public static let maxBytes = 32 << 20

    public let format: Format
    /// The decoded save. Only this class touches it, on one thread at a time (the editor's).
    private var root: [String: Any]

    public init(data: Data) throws {
        guard data.count <= Self.maxBytes else { throw Failure.tooLarge(data.count) }
        // Room for JSON compressed up to 32:1, never more than 128 MiB. Output that fills the room may be cut short,
        // and a cut save written back would be a broken one, so that is refused rather than edited.
        let room = min(max(data.count * 32, 1 << 20), Self.maxBytes * 4)
        var json: Data?
        var format = Format.mv
        if data.first == 0x78 {
            json = BoundedDecode.inflate(data, zlibHeader: true, limit: room)
            format = .mz
        } else if let text = String(data: data, encoding: .utf8) {
            if text.hasPrefix("x"), let bytes = text.data(using: .isoLatin1) {
                json = BoundedDecode.inflate(bytes, zlibHeader: true, limit: room)
                format = .mzBinaryString
            } else {
                json = LZString.decompressFromBase64(text.trimmingCharacters(in: .whitespacesAndNewlines), limit: room)
                    .map { Data($0.utf8) }
            }
        }
        guard let json else { throw Failure.notASave("it does not decode") }
        guard json.count < room else { throw Failure.tooLarge(json.count) }
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              root["party"] != nil, root["variables"] != nil else { throw Failure.notASave("no party or variables") }
        self.root = root
        self.format = format
    }

    /// The save in its original format.
    public func encoded() throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes])
        switch format {
        case .mv:
            guard let text = String(data: json, encoding: .utf8) else { throw Failure.notASave("invalid JSON encoding") }
            return Data(LZString.compressToBase64(text).utf8)
        case .mz, .mzBinaryString:
            let deflated = try Self.zlib(json)
            if format == .mz {
                return deflated
            }
            // One character per byte, as pako's binary strings are; read back through Latin-1.
            return Data(String(deflated.map { Character(UnicodeScalar($0)) }).utf8)
        }
    }

    // MARK: Values

    /// `variables._data[id]`, `switches._data[id]`; missing entries read as the game would (0, false).
    public func variable(_ id: Int) -> Any { element(["variables", "_data"], id) ?? 0 }
    public func `switch`(_ id: Int) -> Bool { element(["switches", "_data"], id) as? Bool ?? false }
    public var gold: Int { (party["_gold"] as? NSNumber)?.intValue ?? 0 }

    public enum ItemKind: String, Sendable { case items = "_items", weapons = "_weapons", armors = "_armors" }

    public func count(_ kind: ItemKind, _ id: Int) -> Int {
        ((party[kind.rawValue] as? [String: Any])?[String(id)] as? NSNumber)?.intValue ?? 0
    }

    public func setVariable(_ id: Int, _ value: Any) { setElement(["variables", "_data"], id, value, fill: 0) }
    public func setSwitch(_ id: Int, _ on: Bool) { setElement(["switches", "_data"], id, on, fill: false) }
    public func setGold(_ amount: Int) { updateParty { $0["_gold"] = amount } }

    /// Zero removes the entry, as `Game_Party.gainItem` does.
    public func setCount(_ kind: ItemKind, _ id: Int, _ count: Int) {
        updateParty { party in
            var table = party[kind.rawValue] as? [String: Any] ?? [:]
            table[String(id)] = count > 0 ? count : nil
            party[kind.rawValue] = table
        }
    }

    private var party: [String: Any] { root["party"] as? [String: Any] ?? [:] }

    private func updateParty(_ change: (inout [String: Any]) -> Void) {
        var party = party
        change(&party)
        root["party"] = party
    }

    /// MV's JsonEx wraps arrays as `{"@c": id, "@a": [...]}` (the id is how references are restored on load);
    /// MZ writes plain arrays. Edits go inside the wrapper, which is kept exactly as it was.
    private func array(_ container: Any?) -> [Any]? {
        (container as? [String: Any])?["@a"] as? [Any] ?? container as? [Any]
    }

    private func rewrap(_ original: Any?, _ array: [Any]) -> Any {
        guard var wrapper = original as? [String: Any], wrapper["@a"] != nil else { return array }
        wrapper["@a"] = array
        return wrapper
    }

    private func element(_ path: [String], _ index: Int) -> Any? {
        guard let object = root[path[0]] as? [String: Any], let array = array(object[path[1]]),
              array.indices.contains(index) else { return nil }
        let value = array[index]
        return value is NSNull ? nil : value
    }

    private func setElement(_ path: [String], _ index: Int, _ value: Any, fill: Any) {
        var object = root[path[0]] as? [String: Any] ?? [:]
        var items = array(object[path[1]]) ?? []
        while items.count <= index {
            items.append(NSNull())
        }
        items[index] = value
        object[path[1]] = rewrap(object[path[1]], items)
        root[path[0]] = object
    }

    // MARK: zlib

    /// zlib framing around Apple's raw deflate: header 78 9C, deflate, Adler-32 big-endian.
    static func zlib(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        let adler = b << 16 | a
        return Data([0x78, 0x9C]) + deflated + Data([
            UInt8(adler >> 24),
            UInt8(adler >> 16 & 0xFF),
            UInt8(adler >> 8 & 0xFF),
            UInt8(adler & 0xFF),
        ])
    }
}
