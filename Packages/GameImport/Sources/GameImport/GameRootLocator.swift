import Diagnostics
import Foundation
import GameCore

/// Files a `.jgp` package or an APK carries beside the game (JoiPlay manifest, controls, configuration).
public struct ImportSidecars: Sendable, Hashable, Codable {
    /// File name → JSON text, each capped at 1 MiB.
    public var files: [String: String] = [:]
    public var notes: [String] = []
    public init() {}
}

public struct LocatedRoot: Sendable, Hashable {
    /// Game root relative to the staging tree (`""` when it is the tree itself).
    public let relativePath: String
    public let sidecars: ImportSidecars
}

/// Finds the canonical game root inside a staged tree and strips known wrappers. Staging is ours,
/// so junk is deleted and APK `x-` prefixes are renamed in place.
public enum GameRootLocator {
    public static let junkNames: Set<String> = ["__MACOSX", ".DS_Store", "Thumbs.db", "desktop.ini", "._.DS_Store"]
    public static let sidecarNames: Set<String> = ["manifest.json", "configuration.json", "gamepad.json"]
    static let markerFiles: Set<String> = [
        "game.ini",
        "index.html",
        "rpg_rt.ldb",
        "rpg_rt.ini",
        "package.json",
        "game.rgssad",
        "game.rgss2a",
        "game.rgss3a",
        "main.lua",
        "nscript.dat",
        "data.win",
    ]
    static let markerDirectories: Set<String> = ["renpy", "www", "game_data", "js"]
    static let archiveKinds: Set<ContainerKind> = [.zip, .sevenZip, .tar, .gzip, .xz, .zstd, .rar4, .rar5, .cab]
    public static let maxCandidates = 16

    /// `chosen` is the candidate the user picked after a `multipleRoots` failure.
    public static func locate(stagingRoot: URL, chosen: String? = nil) throws -> LocatedRoot {
        let fm = FileManager.default
        try stripJunk(under: stagingRoot)
        var sidecars = ImportSidecars()
        var root = stagingRoot

        for _ in 0 ..< 3 {
            let (dirs, files) = try shallow(root)
            // .jgp and similar packages: capture sidecars first, they are not part of the game.
            let sidecarFiles = files.filter { sidecarNames.contains($0.lastPathComponent.lowercased()) }
            if sidecarFiles.count >= 2 {
                for file in sidecarFiles {
                    if let data = try? SmallFileGuard.read(file, maxBytes: 1 << 20), let text = String(data: data, encoding: .utf8) {
                        sidecars.files[file.lastPathComponent] = text
                    }
                    try fm.removeItem(at: file)
                }
                continue
            }
            guard files.isEmpty, dirs.count == 1, let only = dirs.first else { break }
            if only.pathExtension.lowercased() == "app" {
                let autorun = only.appending(path: "Contents/Resources/autorun")
                let resources = only.appending(path: "Contents/Resources")
                root = fm.fileExists(atPath: autorun.path(percentEncoded: false)) ? autorun : resources
                sidecars.notes.append("macOS app bundle unwrapped")
                break
            }
            root = only
        }

        root = try unwrapAPK(root, sidecars: &sidecars)

        let rootRel = rel(root, in: stagingRoot)
        // Candidates are found under the unwrapped root but reported against the staging tree, like the root itself:
        // `Game/{Game.exe, readme, gamedata/}` must give `Game/gamedata`, not `gamedata`.
        let candidates = try candidateRoots(under: root).map { $0.isEmpty ? rootRel : rootRel.isEmpty ? $0 : rootRel + "/" + $0 }
        if hasMarker(root) || candidates.isEmpty {
            return LocatedRoot(relativePath: rootRel, sidecars: sidecars)
        }
        if candidates.count == 1 {
            return LocatedRoot(relativePath: candidates[0], sidecars: sidecars)
        }
        if let chosen, candidates.contains(chosen) {
            return LocatedRoot(relativePath: chosen, sidecars: sidecars)
        }
        throw ImportFailure.multipleRoots(candidates)
    }

    /// An archive that arrived alone (a readme or two beside it does not count). Beside a game's own marker (a page
    /// with `game.js` and `data.zip`) the archive is the game's data, not a wrapper.
    public static func nestedArchive(in root: URL) -> URL? {
        var files: [URL] = []
        var marked = false
        try? LazyDirectoryWalker.walk(root: root) { entry in
            let name = entry.url.lastPathComponent.lowercased()
            if entry.isDirectory {
                marked = markerDirectories.contains(name)
                return marked ? .stop : .continue
            }
            marked = markerFiles.contains(name) || entry.url.pathExtension.lowercased() == "pck"
            files.append(entry.url)
            return marked || files.count > 3 ? .stop : .continue
        }
        guard !marked, files.count <= 3 else { return nil }
        let archives = files.filter { (try? ContainerSniffer.identify($0)).map(archiveKinds.contains) ?? false }
        return archives.count == 1 ? archives[0] : nil
    }

    /// Android APK: `assets/x-game` (Ren'Py, prefixed) becomes `assets/game`; `assets/game` or `assets/www` (MV) is used as is.
    private static func unwrapAPK(_ root: URL, sidecars: inout ImportSidecars) throws -> URL {
        let fm = FileManager.default
        let assets = root.appending(path: "assets")
        if fm.fileExists(atPath: assets.appending(path: "x-game").path(percentEncoded: false)) {
            try stripAPKPrefixes(in: assets.appending(path: "x-game"))
            try fm.moveItem(at: assets.appending(path: "x-game"), to: assets.appending(path: "game"))
            for extra in ["private.mp3", "x-renpy"] where fm.fileExists(atPath: assets.appending(path: extra).path(percentEncoded: false)) {
                if extra == "x-renpy" {
                    try fm.moveItem(at: assets.appending(path: extra), to: assets.appending(path: "renpy"))
                } else {
                    try fm.removeItem(at: assets.appending(path: extra))
                }
            }
            sidecars.notes.append("Android APK unwrapped (x- prefixes stripped)")
            return assets
        } else if ["game", "www"].contains(where: { fm.fileExists(atPath: assets.appending(path: $0).path(percentEncoded: false)) }) {
            sidecars.notes.append("Android APK unwrapped")
            return assets
        }
        return root
    }

    // MARK: - Helpers

    private static func stripJunk(under root: URL) throws {
        var victims: [URL] = []
        try LazyDirectoryWalker.walk(root: root, skipHidden: false) { entry in
            let name = entry.url.lastPathComponent
            if junkNames.contains(name) || name.hasPrefix("._") {
                victims.append(entry.url)
                return entry.isDirectory ? .skipDescendants : .continue
            }
            return .continue
        }
        for v in victims {
            try FileManager.default.removeItem(at: v)
        }
        if !victims.isEmpty {
            OPLog.log(.importer, .info, "stripped \(victims.count) junk items")
        }
    }

    private static func stripAPKPrefixes(in dir: URL) throws {
        var renames: [(URL, URL)] = []
        try LazyDirectoryWalker.walk(root: dir, skipHidden: false) { entry in
            if entry.url.lastPathComponent.hasPrefix("x-") {
                renames.append((
                    entry.url,
                    entry.url.deletingLastPathComponent().appending(path: String(entry.url.lastPathComponent.dropFirst(2)))
                ))
            }
            return .continue
        }
        // Deepest first so parent renames do not invalidate child URLs.
        for (from, to) in renames.sorted(by: { $0.0.pathComponents.count > $1.0.pathComponents.count }) {
            try FileManager.default.moveItem(at: from, to: to)
        }
    }

    private static func shallow(_ dir: URL) throws -> (dirs: [URL], files: [URL]) {
        let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])
        var dirs: [URL] = [], files: [URL] = []
        for item in items {
            if try (item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                dirs.append(item)
            } else {
                files.append(item)
            }
        }
        return (dirs.sorted { $0.path() < $1.path() }, files.sorted { $0.path() < $1.path() })
    }

    static func hasMarker(_ dir: URL) -> Bool {
        guard let (dirs, files) = try? shallow(dir) else { return false }
        if files
            .contains(where: { markerFiles.contains($0.lastPathComponent.lowercased()) || $0.pathExtension.lowercased() == "pck" }) {
            return true
        }
        return dirs.contains { markerDirectories.contains($0.lastPathComponent.lowercased()) }
    }

    /// Directories at depth ≤ 3 that look like a game root, bounded to `maxCandidates`.
    static func candidateRoots(under root: URL) throws -> [String] {
        var found: [String] = []
        if hasMarker(root) {
            found.append("")
        }
        try LazyDirectoryWalker.walk(root: root) { entry in
            guard entry.isDirectory else { return .continue }
            let depth = entry.relativePath.split(separator: "/").count
            if depth > 3 {
                return .skipDescendants
            }
            if hasMarker(entry.url) {
                found.append(entry.relativePath)
                if found.count >= maxCandidates {
                    return .stop
                }
                return .skipDescendants
            }
            return .continue
        }
        return found
    }

    static func rel(_ url: URL, in root: URL) -> String {
        let r = root.resolvingSymlinksInPath().path(percentEncoded: false)
        var p = url.resolvingSymlinksInPath().path(percentEncoded: false)
        if p.hasPrefix(r) {
            p.removeFirst(r.count)
        }
        while p.hasPrefix("/") {
            p.removeFirst()
        }
        while p.hasSuffix("/") {
            p.removeLast()
        }
        return p
    }
}
