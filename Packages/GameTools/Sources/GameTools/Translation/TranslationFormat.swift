import Foundation
import GameCore

/// The translation pack formats OmniPlay understands, decided from what is in the pack; nothing is called a
/// translation pack just for being a ZIP.
public enum TranslationFormat: String, Sendable, Codable, CaseIterable {
    /// Ren'Py's own `game/tl/<language>/`: overlay files plus a language switch.
    case renpyTL
    /// MTool's flat `{ "original": "translation" }` JSON, matched at the engine's text hooks.
    case mtoolJSON
    /// A copy of the game's own data files with the text replaced (Translator++ and the like): an overlay.
    case patchedTree
    /// Replacement assets (translated images, fonts).
    case genericOverlay

    public var title: String {
        switch self {
        case .renpyTL: "Ren'Py translation"
        case .mtoolJSON: "Text dictionary (MTool)"
        case .patchedTree: "Translated game files"
        case .genericOverlay: "Translated images and files"
        }
    }
}

public struct TranslationDetection: Sendable, Hashable {
    public var format: TranslationFormat
    /// `tl/<language>` for Ren'Py packs; empty when the pack does not say.
    public var language: String
    /// The MTool dictionary, relative to the pack's root.
    public var dictionary: String?
    public var entries: Int
    public var refusal: String?
}

public enum TranslationFormatDetector {
    public static let dictionaryLimit = 64 << 20

    /// `files` are relative to the staged pack's root (which mirrors the game's); `gameHas` says whether the game ships
    /// a file at a path, for telling a patched copy of its data from arbitrary files.
    public static func detect(root: URL, files: [String], engine: EngineFamily, gameHas: (String) -> Bool) -> TranslationDetection {
        let lower = files.map { $0.lowercased() }
        if engine == .renpy, let tl = lower.first(where: { $0.hasPrefix("game/tl/") }) {
            let parts = tl.split(separator: "/")
            let language = parts.count > 3 ? String(parts[2]) : ""
            if language == "none" || language.isEmpty {
                return TranslationDetection(
                    format: .renpyTL,
                    language: "",
                    dictionary: nil,
                    entries: 0,
                    refusal: "Its tl folder names no language."
                )
            }
            return TranslationDetection(format: .renpyTL, language: language, dictionary: nil, entries: files.count, refusal: nil)
        }
        let jsons = files.filter { $0.lowercased().hasSuffix(".json") }
        // MTool: a JSON that is not one of the game's own data files and holds a flat string-to-string object.
        for json in jsons where !gameHas(json) {
            if let count = mtoolEntries(root.appending(path: json)) {
                return TranslationDetection(format: .mtoolJSON, language: "", dictionary: json, entries: count, refusal: nil)
            }
        }
        let mirrored = files.filter(gameHas)
        if !mirrored.isEmpty, mirrored.count * 2 >= files.count {
            return TranslationDetection(format: .patchedTree, language: "", dictionary: nil, entries: mirrored.count, refusal: nil)
        }
        if files.isEmpty {
            return TranslationDetection(format: .genericOverlay, language: "", dictionary: nil, entries: 0, refusal: "It holds no files.")
        }
        let assets = lower
            .filter {
                ["png", "jpg", "jpeg", "webp", "ttf", "otf", "woff", "woff2", "ogg", "m4a", "rpgmvp", "png_"]
                    .contains(($0 as NSString).pathExtension)
            }
        if assets.count * 2 >= files.count {
            return TranslationDetection(format: .genericOverlay, language: "", dictionary: nil, entries: assets.count, refusal: nil)
        }
        return TranslationDetection(
            format: .genericOverlay, language: "", dictionary: nil, entries: 0,
            refusal: "This is not a translation OmniPlay recognises: no tl folder, no text dictionary, "
                + "and its files do not match the game's (\(files.prefix(3).joined(separator: ", "))…)."
        )
    }

    /// The number of entries when `url` is a flat `{string: string}` JSON object within the size limit.
    public static func mtoolEntries(_ url: URL) -> Int? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= dictionaryLimit,
              let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], !object.isEmpty,
              object.values.allSatisfy({ $0 is String }) else { return nil }
        return object.count
    }
}
