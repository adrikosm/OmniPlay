import Foundation
import GameCore

public enum SaveFormat: String, Sendable, Codable, Hashable {
    case mvLZString, mzZlib, rgssMarshal, renpySave, renpyPersistent, easyrpgLSD, webStorageText, unknown

    /// The family a file of this format belongs to.
    public var family: SaveFamily? {
        switch self {
        case .mvLZString, .webStorageText: .webLocalStorage
        case .mzZlib: .webIndexedDB
        case .rgssMarshal: .rgssMarshal
        case .renpySave, .renpyPersistent: .renpySave
        case .easyrpgLSD: .easyrpgLSD
        case .unknown: nil
        }
    }
}

public enum TitleMatch: Sendable, Hashable { case same, foreign(String), unknown }

public struct SaveValidation: Sendable, Hashable {
    public let format: SaveFormat
    public let matchesFamily: Bool
    public let titleMatch: TitleMatch
    public let versionHint: String?
    public let warnings: [String]
    /// Refuse outright: the bytes are not a save we recognise.
    public var isAcceptable: Bool { format != .unknown }
    /// Needs the player's explicit confirmation before it touches the game's saves.
    public var needsConfirmation: Bool { !matchesFamily || {
        if case .foreign = titleMatch {
            true
        } else {
            false
        }
    }() }
}

/// Recognises save files by bounded header reads. Loading a foreign or wrong-family save is the realistic attack
/// surface, so anything unrecognised is refused with its magic bytes named, and foreign titles are flagged.
public enum SaveValidator {
    public static let headBytes = 64 << 10

    public static func validate(
        file: URL,
        family: SaveFamily,
        expectedTitleHash: String? = nil,
        manifestTitleHash: String? = nil
    ) -> SaveValidation {
        let handle = try? FileHandle(forReadingFrom: file)
        defer { try? handle?.close() }
        let head = (try? handle?.read(upToCount: headBytes)) ?? Data()
        // A ZIP names its members again in the central directory at its end. A desktop Ren'Py save stores its
        // screenshot first, so `json` and `log` are often past the head; the bounded tail still lists them.
        var tail = Data()
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]), let handle, let size = try? handle.seekToEnd(), size > UInt64(headBytes) {
            try? handle.seek(toOffset: max(UInt64(headBytes), size - UInt64(headBytes)))
            tail = (try? handle.readToEnd()) ?? Data()
        }
        let ext = file.pathExtension.lowercased()
        var warnings: [String] = []
        var version: String?
        let format = sniff(head, tail: tail, ext: ext, version: &version, warnings: &warnings)
        let matches = format.family == family || (format == .webStorageText && family == .webIndexedDB)
        if format ==
            .unknown {
            warnings.append("unrecognised save: starts with \(head.prefix(4).map { String(format: "%02X", $0) }.joined(separator: " "))")
        }
        let title: TitleMatch = switch (manifestTitleHash, expectedTitleHash) {
        case let (m?, e?): m == e ? .same : .foreign(m)
        default: .unknown
        }
        return SaveValidation(format: format, matchesFamily: matches, titleMatch: title, versionHint: version, warnings: warnings)
    }

    static func sniff(_ head: Data, tail: Data = Data(), ext: String, version: inout String?, warnings: inout [String]) -> SaveFormat {
        guard !head.isEmpty else { return .unknown }
        let bytes = [UInt8](head.prefix(16))
        if bytes.starts(with: [0x04, 0x08]), ["rxdata", "rvdata", "rvdata2"].contains(ext) {
            return .rgssMarshal
        }
        if head
            .starts(with: Data("LcfSaveData".utf8)) ||
            (bytes.count > 1 && head.dropFirst(1).starts(with: Data("LcfSaveData".utf8))) {
            return .easyrpgLSD
        }
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            if ext == "save" || ext.isEmpty {
                let names = head + tail
                let hasJSON = names.range(of: Data("json".utf8)) != nil, hasLog = names.range(of: Data("log".utf8)) != nil
                if hasJSON, hasLog {
                    version = renpyVersion(in: head)
                    return .renpySave
                }
                warnings.append("ZIP without the Ren'Py json and log members")
            }
            return .unknown
        }
        if bytes.count >= 2, bytes[0] == 0x78, [0x9C, 0xDA, 0x01, 0x5E].contains(bytes[1]) {
            guard let inflated = BoundedDecode.inflate(head, zlibHeader: true)
            else { warnings.append("zlib stream does not inflate"); return .unknown }
            if ext == "rmmzsave" || inflated.starts(with: Data("{".utf8)) {
                return .mzZlib
            }
            if ext == "" || ext == "persistent" || inflated.first == 0x80 {
                return .renpyPersistent
            }
            return .mzZlib
        }
        if ext == "rpgsave" {
            guard let text = String(data: head, encoding: .ascii), let json = BoundedDecode.lzStringBase64(text) else {
                warnings.append("not LZString base64"); return .unknown
            }
            if json.contains("Game_System") {
                return .mvLZString
            }
            warnings.append("LZString decodes but holds no Game_System object")
            return .unknown
        }
        if ["webstorage", "txt", "json"].contains(ext), String(data: head, encoding: .utf8) != nil {
            return .webStorageText
        }
        return .unknown
    }

    /// `_renpy_version` inside the stored `json` member, when the member is stored or inflates.
    static func renpyVersion(in head: Data) -> String? {
        let marker = Data("\"_renpy_version\"".utf8)
        var text = String(bytes: head, encoding: .isoLatin1) ?? ""
        if head.range(of: marker) == nil, let start = head.range(of: Data("json".utf8))?.upperBound {
            let candidate = head[start...]
            if let inflated = BoundedDecode.inflate(Data(candidate.prefix(32 << 10)), zlibHeader: false) {
                text = String(bytes: inflated, encoding: .utf8) ?? text
            }
        }
        guard let range = text.range(of: "\"_renpy_version\"") else { return nil }
        // The value is a string ("8.1.3") in older saves and a list ([8, 5, 3]) in newer ones.
        let tail = text[range.upperBound...].drop { $0 == ":" || $0 == " " }
        let end = tail.hasPrefix("[") ? (tail.firstIndex(of: "]").map { tail.index(after: $0) } ?? tail.endIndex)
            : (tail.firstIndex { $0 == "," || $0 == "}" } ?? tail.endIndex)
        let raw = tail[..<end].trimmingCharacters(in: CharacterSet(charactersIn: "\"[] "))
        return raw.isEmpty ? nil : raw.replacingOccurrences(of: ", ", with: ".").replacingOccurrences(of: ",", with: ".")
    }
}
