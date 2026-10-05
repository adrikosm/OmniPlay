import Diagnostics
import Foundation
import GameCore
import OverlayVFS

/// The RPG Maker Run Time Packages, which OmniPlay never ships: Enterbrain's assets are licensed to the
/// person who installed the Maker, so an RTP arrives only as a folder the user imports from their own
/// installation. The manager copies one in, checks it looks like an RTP, and answers the one question the
/// launch path asks — will this game find its graphics, or should the player be told before the engine
/// raises an error nobody can act on.
public enum RTPManager {
    public enum Status: Sendable, Equatable {
        /// The engine family has no RTP, or the game ships every asset it uses.
        case notRequired
        case installed(RTPFamily)
        case missing(RTPFamily, named: String?)
    }

    public enum ImportError: Error, Equatable {
        case notADirectory
        case notAnRTP(found: [String])
    }

    /// Folders an RTP of the family has. A folder with none of them is something else. RGSS RTPs split assets
    /// into `Graphics/` and `Audio/`; 2000 and 2003 keep one folder per asset kind at the top.
    public static func expectedSubfolders(_ family: RTPFamily) -> Set<String> {
        switch family {
        case .xp, .vx, .vxAce: ["graphics", "audio"]
        case .rpg2000, .rpg2003: ["charset", "chipset", "system", "music", "sound"]
        }
    }

    public static func isInstalled(_ family: RTPFamily, paths: AppPaths) -> Bool {
        looksLikeRTP(paths.rtpRoot(family), family)
    }

    /// What the player needs to know before launching. `warnings` carries the RTP name the game's `Game.ini`
    /// asked for, which is worth repeating verbatim: the installers are named the same way.
    public static func status(for descriptor: GameDescriptor, paths: AppPaths) -> Status {
        guard let family = LayerSetBuilder.rtpFamily(for: descriptor.engine) else { return .notRequired }
        let named = descriptor.warnings.compactMap { warning -> String? in
            if case let .rtpRequired(name) = warning {
                return name
            }
            return nil
        }.first
        if isInstalled(family, paths: paths) {
            return .installed(family)
        }
        // No `rtpRequired` warning means detection saw the game's own Graphics folder; it needs nothing.
        return named == nil ? .notRequired : .missing(family, named: named)
    }

    /// One line for the player, and the reason it is not an engine error: mkxp would only say "file not found".
    public static func explanation(for status: Status) -> String? {
        guard case let .missing(family, named) = status else { return nil }
        let name = named.map { "the \($0) RTP" } ?? "the \(family.rawValue) RTP"
        return "This game uses \(name), which it does not include. Import it from your own RPG Maker "
            + "(a folder, ZIP or installer); without it the game stops at the first picture it cannot find."
    }

    /// Copies a user-chosen folder into `RTP/<family>/`, file by file. Returns how many files landed.
    /// An existing install is added to rather than replaced: the official installers ship the tiers separately.
    @discardableResult
    public static func install(
        from folder: URL,
        family: RTPFamily,
        paths: AppPaths,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> Int {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue else { throw ImportError.notADirectory }
        let root = try locateRoot(in: folder, family: family)
        let destination = paths.rtp(family)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var files: [(URL, URL)] = []
        try LazyDirectoryWalker.walk(root: root) { entry in
            if !entry.isDirectory {
                files.append((entry.url, destination.appending(path: entry.relativePath)))
            }
            return .continue
        }
        var copied = 0
        for (source, target) in files {
            try Task.checkCancellation()
            try await ChunkedCopier.copy(from: source, to: target)
            copied += 1
            progress?(copied)
        }
        OPLog.log(.filesystem, .info, "imported \(copied) files into the \(family.rawValue) RTP")
        return copied
    }

    /// The release an installed RTP was recognised as at import ("Official English, 465 of 465 files"), when a
    /// fingerprint could name it. Kept beside the files so Settings need not rescan a thousand of them.
    public static func variant(_ family: RTPFamily, paths: AppPaths) -> String? {
        (try? String(contentsOf: variantFile(family, paths: paths), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func recordVariant(_ name: String?, family: RTPFamily, paths: AppPaths) {
        let file = variantFile(family, paths: paths)
        if let name {
            try? Data(name.utf8).write(to: file, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func variantFile(_ family: RTPFamily, paths: AppPaths) -> URL {
        paths.rtpRoot(family).appending(path: ".omniplay-variant")
    }

    /// Removes an installed RTP. The files are the user's own copy; nothing else depends on them.
    public static func remove(_ family: RTPFamily, paths: AppPaths) throws {
        try FileManager.default.removeItem(at: paths.rtp(family))
        try FileManager.default.createDirectory(at: paths.rtp(family), withIntermediateDirectories: true)
    }

    /// The official installers unpack one level deep ("RPGVXAce/Graphics"), and people zip either level, sometimes
    /// inside one more folder ("RTP/RPG2003/CharSet"). Accepts the folder or a descendant up to two levels down, and
    /// refuses anything with no RTP-shaped folder at all. A macOS zip's `__MACOSX` resource forks are never the RTP.
    public static func locateRoot(in folder: URL, family: RTPFamily) throws -> URL {
        if looksLikeRTP(folder, family) {
            return folder
        }
        let top = contents(of: folder)
        var level = top.map { folder.appending(path: $0, directoryHint: .isDirectory) }
        for _ in 0 ..< 2 {
            level = level.filter { $0.lastPathComponent != "__MACOSX" }
            if let found = level.first(where: { looksLikeRTP($0, family) }) {
                return found
            }
            level = level.flatMap { dir in contents(of: dir).map { dir.appending(path: $0, directoryHint: .isDirectory) } }
        }
        throw ImportError.notAnRTP(found: Array(top.prefix(8)))
    }

    private static func looksLikeRTP(_ folder: URL, _ family: RTPFamily) -> Bool {
        let expected = expectedSubfolders(family)
        return contents(of: folder).contains { expected.contains($0.lowercased()) }
    }

    private static func contents(of url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? [])
            .filter { !$0.hasPrefix(".") }
    }
}
