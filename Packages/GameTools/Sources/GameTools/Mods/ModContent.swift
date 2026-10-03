import Foundation
import GameCore

/// What a mod holds, decided from its files and the game it is for.
public enum ModContentType: String, Sendable, Codable, CaseIterable {
    case renpyScript, renpyArchive, mvmzPlugin, mvmzData, mvmzAsset, rgssAsset, rgssScriptPatch, genericOverlay

    public var title: String {
        switch self {
        case .renpyScript: "Ren'Py scripts"
        case .renpyArchive: "Ren'Py archive"
        case .mvmzPlugin: "Plugins"
        case .mvmzData: "Game data"
        case .mvmzAsset, .rgssAsset: "Graphics and sound"
        case .rgssScriptPatch: "Ruby script patch"
        case .genericOverlay: "Replacement files"
        }
    }

    /// Scripts and data change what a save means; toggling such a mod takes a save snapshot first.
    public var affectsSaves: Bool {
        switch self {
        case .renpyScript, .renpyArchive, .mvmzPlugin, .mvmzData, .rgssScriptPatch: true
        case .mvmzAsset, .rgssAsset, .genericOverlay: false
        }
    }
}

public struct ModValidation: Sendable, Hashable {
    public var contentType: ModContentType
    public var engineCompatible: Bool
    /// Every file, relative to the mod root (which mirrors the game's root).
    public var files: [String]
    public var nativeBinaries: [String]
    public var bytes: Int64
    public var warnings: [String]
    /// MV/MZ plugin names under `js/plugins/`, for the composed `plugins.js`.
    public var plugins: [String]

    /// Why the mod cannot be installed, or nil.
    public var refusal: String? {
        if let binary = nativeBinaries.first {
            return "It contains a program for another platform (\(binary)); mods can only replace game files."
        }
        if !engineCompatible {
            return "Its files are for a different engine than this game's."
        }
        if files.isEmpty {
            return "It holds no files."
        }
        return nil
    }
}

/// Classifies a staged mod and normalises its layout to the game's root before it is installed. Paths already passed
/// the import safety policy when they were staged; this decides whether they belong in this game at all.
public enum ModValidator {
    static let nativeExtensions: Set<String> = [
        "dll",
        "exe",
        "dylib",
        "so",
        "bundle",
        "framework",
        "node",
        "app",
        "msi",
        "com",
        "bat",
        "cmd",
    ]

    /// A mod path as the MV/MZ web root sees it: without the `www/` a desktop deployment keeps everything under.
    public static func webRelative(_ path: String) -> String {
        path.lowercased().hasPrefix("www/") ? String(path.dropFirst(4)) : path
    }

    /// Where a lone file goes in the game's tree, or nil when a lone file of that kind needs a folder around it.
    public static func placement(forSingleFile name: String, engine: EngineFamily) -> String? {
        let ext = (name as NSString).pathExtension.lowercased()
        switch (engine, ext) {
        case (.renpy, "rpy"), (.renpy, "rpyc"), (.renpy, "rpa"), (.renpy, "rpym"): return "game/\(name)"
        case (.rpgMakerMV, "js"), (.rpgMakerMZ, "js"): return "js/plugins/\(name)"
        case (.rpgMakerXP, "rb"), (.rpgMakerVX, "rb"), (.rpgMakerVXAce, "rb"): return "Scripts/\(name)"
        default: return nil
        }
    }

    /// Moves a mod's files so they line up with the game's root: a mod zipped with a single top folder is unwrapped;
    /// Ren'Py scripts at the mod's root go under `game/`; MV's `www/` is dropped when the game's root has none, and
    /// added when the game keeps everything under it (a desktop deployment) and the mod does not.
    public static func normalise(_ root: URL, engine: EngineFamily, gameHasWWW: Bool) throws {
        let fm = FileManager.default
        func children(_ url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []).filter { !$0.lastPathComponent.hasPrefix(".") }
        }
        func isDirectory(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        /// Moves a folder's contents into `destination`, merging folders that are already there. Two files with one
        /// name refuse the mod: nothing is skipped and then deleted with its folder.
        func merge(_ folder: URL, into destination: URL) throws {
            for item in children(folder) {
                let target = destination.appending(path: item.lastPathComponent)
                if !fm.fileExists(atPath: target.path(percentEncoded: false)) {
                    try fm.moveItem(at: item, to: target)
                } else if isDirectory(item), isDirectory(target) {
                    try merge(item, into: target)
                } else {
                    throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target.path(percentEncoded: false)])
                }
            }
            try fm.removeItem(at: folder)
        }
        /// A wrapper is renamed out of the way first, so a child with the wrapper's own name (`MyMod/MyMod/`) can land.
        func hoist(_ folder: URL) throws {
            let aside = root.appending(path: ".unwrap-\(UUID().uuidString)", directoryHint: .isDirectory)
            try fm.moveItem(at: folder, to: aside)
            try merge(aside, into: root)
        }
        // One folder at the top that is not itself a game folder: the zip's own wrapper, possibly wrapped again.
        let gameFolders: Set = [
            "game", "tl", "www", "js", "data", "img", "audio", "graphics", "fonts", "scripts", "movies", "effects", "icon", "css",
        ]
        for _ in 0 ..< 8 {
            let top = children(root)
            guard top.count == 1, let only = top.first, isDirectory(only), !gameFolders.contains(only.lastPathComponent.lowercased())
            else { break }
            try hoist(only)
        }
        if engine == .rpgMakerMV || engine == .rpgMakerMZ {
            let www = root.appending(path: "www", directoryHint: .isDirectory)
            if !gameHasWWW, fm.fileExists(atPath: www.path(percentEncoded: false)) {
                try hoist(www)
            } else if gameHasWWW, !fm.fileExists(atPath: www.path(percentEncoded: false)), !children(root).isEmpty {
                let aside = root.appending(path: ".www-\(UUID().uuidString)", directoryHint: .isDirectory)
                try fm.createDirectory(at: aside, withIntermediateDirectories: true)
                for item in children(root) {
                    try fm.moveItem(at: item, to: aside.appending(path: item.lastPathComponent))
                }
                try fm.moveItem(at: aside, to: www)
            }
        }
        if engine == .renpy, !fm.fileExists(atPath: root.appending(path: "game").path(percentEncoded: false)) {
            // Scripts, or a `tl/` translation folder, zipped to be dropped into `game/`.
            let scripts = children(root).filter {
                ["rpy", "rpyc", "rpa", "rpym"].contains($0.pathExtension.lowercased()) || $0.lastPathComponent.lowercased() == "tl"
            }
            if !scripts.isEmpty {
                let game = root.appending(path: "game", directoryHint: .isDirectory)
                try fm.createDirectory(at: game, withIntermediateDirectories: true)
                for item in children(root) where item.lastPathComponent != "game" {
                    try fm.moveItem(at: item, to: game.appending(path: item.lastPathComponent))
                }
            }
        }
    }

    public static func validate(root: URL, engine: EngineFamily) -> ModValidation {
        var files: [String] = []
        var bytes: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        while let url = enumerator?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            let rel = String(url.path(percentEncoded: false).dropFirst(root.path(percentEncoded: false).count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !rel.isEmpty, rel != "mod.json", !rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
            files.append(rel)
            bytes += Int64(values.fileSize ?? 0)
        }
        files.sort()
        let lower = files.map { $0.lowercased() }
        let exts = Set(lower.map { ($0 as NSString).pathExtension })
        let native = files
            .filter { nativeExtensions.contains(($0 as NSString).pathExtension.lowercased()) || $0.lowercased().contains(".framework/") }
        var warnings: [String] = []
        let web = lower.map(webRelative)
        let plugins = files.filter { webRelative($0.lowercased()).hasPrefix("js/plugins/") && $0.lowercased().hasSuffix(".js") }
            .map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }

        let type: ModContentType
        var compatible = true
        let renpyFiles = !exts.isDisjoint(with: ["rpy", "rpyc", "rpym"])
        switch engine {
        case .renpy:
            type = renpyFiles ? .renpyScript : exts.contains("rpa") ? .renpyArchive : .genericOverlay
            compatible = !web.contains { $0.hasPrefix("js/plugins/") } && !exts.contains("rb")
        case .rpgMakerMV, .rpgMakerMZ:
            type = !plugins.isEmpty ? .mvmzPlugin : web.contains { $0.hasPrefix("data/") } ? .mvmzData
                : web.contains { $0.hasPrefix("img/") || $0.hasPrefix("audio/") } ? .mvmzAsset : .genericOverlay
            compatible = !renpyFiles && !exts.contains("rb")
            if web.contains("js/plugins.js") {
                warnings.append("Its own js/plugins.js is not installed; its plugins are added to the game's list instead.")
            }
        case .rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce:
            type = exts.contains("rb") ? .rgssScriptPatch : .rgssAsset
            compatible = !renpyFiles && plugins.isEmpty
            if type == .rgssScriptPatch {
                warnings.append("Ruby script patches are not applied yet; the mod's other files are.")
            }
        default:
            type = .genericOverlay
            compatible = !renpyFiles
        }
        return ModValidation(
            contentType: type, engineCompatible: compatible, files: files, nativeBinaries: native, bytes: bytes,
            warnings: warnings, plugins: plugins
        )
    }
}

/// A file more than one enabled mod provides; the highest priority wins.
public struct ModConflict: Sendable, Hashable, Identifiable {
    public let path: String
    public let winner: String
    public let losers: [String]
    public var id: String { path }
}

public enum ModConflicts {
    public struct Input: Sendable {
        public let id: String
        public let priority: Int
        public let files: [String]
        public init(id: String, priority: Int, files: [String]) {
            (self.id, self.priority, self.files) = (id, priority, files)
        }
    }

    /// Overlaps between enabled mods, case-insensitively (the resolver matches paths that way). `js/plugins.js` is
    /// left out: plugin lists are merged, not replaced. At most `limit` are returned.
    public static func analyze(_ mods: [Input], limit: Int = 1000) -> [ModConflict] {
        struct Owner {
            let id: String
            let priority: Int
            let path: String
        }
        var owners: [String: [Owner]] = [:]
        for mod in mods {
            for file in mod.files where ModValidator.webRelative(file.lowercased()) != "js/plugins.js" {
                owners[file.lowercased(), default: []].append(Owner(id: mod.id, priority: mod.priority, path: file))
            }
        }
        return owners.values.filter { $0.count > 1 }.map { list in
            let ranked = list.sorted { $0.priority > $1.priority }
            return ModConflict(path: ranked[0].path, winner: ranked[0].id, losers: ranked.dropFirst().map(\.id))
        }
        .sorted { $0.path < $1.path }
        .prefix(limit).map(\.self)
    }
}

/// MV/MZ `js/plugins.js` for the enabled mods: the game's own list, plus each mod plugin not already in it, switched
/// on and given the defaults its header declares (a plugin reads missing parameters as undefined).
public enum PluginsJSMerger {
    public struct Plugin: Sendable {
        public let name: String
        public let source: String
        public init(name: String, source: String) {
            (self.name, self.source) = (name, source)
        }
    }

    /// Nil when the game's `plugins.js` cannot be read as `var $plugins = [...]`.
    public static func compose(original: String, plugins: [Plugin]) -> String? {
        guard let open = original.firstIndex(of: "["), let close = original.lastIndex(of: "]"), open < close,
              var list = (try? JSONSerialization.jsonObject(with: Data(original[open ... close].utf8))) as? [[String: Any]]
        else { return nil }
        for plugin in plugins {
            if let i = list.firstIndex(where: { ($0["name"] as? String) == plugin.name }) {
                list[i]["status"] = true
            } else {
                list.append([
                    "name": plugin.name, "status": true, "description": description(plugin.source),
                    "parameters": defaults(plugin.source),
                ])
            }
        }
        guard let json = try? JSONSerialization.data(withJSONObject: list, options: [.withoutEscapingSlashes]),
              let text = String(data: json, encoding: .utf8) else { return nil }
        return "// Composed by OmniPlay from the game's plugins.js and its enabled mods.\nvar $plugins =\n"
            + text + ";\n"
    }

    /// The first plugin comment block (`/*: ... */`, the English one when there are several).
    static func header(_ source: String) -> Substring {
        guard let start = source.range(of: "/*:") else { return "" }
        let end = source.range(of: "*/", range: start.upperBound ..< source.endIndex)?.lowerBound ?? source.endIndex
        return source[start.upperBound ..< end]
    }

    static func description(_ source: String) -> String {
        header(source).split(separator: "\n").lazy.compactMap { line -> String? in
            guard let r = line.range(of: "@plugindesc") else { return nil }
            return line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        }.first ?? ""
    }

    /// `@param name` followed by its `@default value`, as strings (MV/MZ store every parameter as a string).
    static func defaults(_ source: String) -> [String: String] {
        var out: [String: String] = [:]
        var current: String?
        for line in header(source).split(separator: "\n") {
            let text = line.trimmingCharacters(in: CharacterSet(charactersIn: " *\t"))
            if text.hasPrefix("@param ") {
                current = String(text.dropFirst("@param ".count)).trimmingCharacters(in: .whitespaces)
                if let current {
                    out[current] = ""
                }
            } else if text.hasPrefix("@default"), let name = current {
                out[name] = String(text.dropFirst("@default".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return out
    }
}
