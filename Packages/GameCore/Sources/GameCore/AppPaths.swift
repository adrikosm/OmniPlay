import Foundation

/// User-imported RTPs only; OmniPlay never bundles Enterbrain/Kadokawa assets.
public enum RTPFamily: String, CaseIterable, Sendable, Codable {
    case xp = "XP", vx = "VX", vxAce = "VXAce", rpg2000 = "RPG2000", rpg2003 = "RPG2003"
}

/// The on-device storage layout (§15.2). Everything persistent lives under
/// `Library/Application Support/OmniPlay/`; caches under `Library/Caches/OmniPlay/`; the only
/// user-visible folder is `Documents/OmniPlay/Saves-Export/`.
public struct AppPaths: Sendable, Equatable {
    public let root: URL
    public let cachesRoot: URL
    public let exportsRoot: URL

    public init(root: URL, cachesRoot: URL, exportsRoot: URL) {
        self.root = root
        self.cachesRoot = cachesRoot
        self.exportsRoot = exportsRoot
    }

    public static func applicationDefault(fileManager: FileManager = .default) throws -> AppPaths {
        func dir(_ d: FileManager.SearchPathDirectory) throws -> URL {
            try fileManager.url(for: d, in: .userDomainMask, appropriateFor: nil, create: true)
        }
        return try AppPaths(
            root: dir(.applicationSupportDirectory).appending(path: "OmniPlay", directoryHint: .isDirectory),
            cachesRoot: dir(.cachesDirectory).appending(path: "OmniPlay", directoryHint: .isDirectory),
            exportsRoot: dir(.documentDirectory).appending(path: "OmniPlay/Saves-Export", directoryHint: .isDirectory)
        )
    }

    /// A layout rooted in one temporary directory, for tests.
    public static func temporary() -> AppPaths {
        let base = FileManager.default.temporaryDirectory.appending(path: "OmniPlay-\(UUID().uuidString)", directoryHint: .isDirectory)
        return AppPaths(
            root: base.appending(path: "Support"),
            cachesRoot: base.appending(path: "Caches"),
            exportsRoot: base.appending(path: "Export")
        )
    }

    public func database() -> URL { root.appending(path: "Database/omniplay.sqlite") }
    public func games() -> URL { sub("Games") }
    /// Paths persisted in the database are relative to `root`, because the app container moves between installs.
    public func stored(_ url: URL) -> String {
        let rootPath = root.path(percentEncoded: false)
        let full = url.path(percentEncoded: false)
        return full.hasPrefix(rootPath) ? String(full.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")) : full
    }

    public func url(forStored path: String) -> URL {
        path.hasPrefix("/") ? URL(filePath: path) : root.appending(path: path)
    }

    public func logsRoot() -> URL { sub("Logs") }

    /// Saves kept after a game is deleted, keyed by title fingerprint; restored on re-import.
    public func rescuedSaves() -> URL { sub("RescuedSaves") }
    public func game(_ id: GameID) -> URL { games().appending(path: id.description, directoryHint: .isDirectory) }
    public func runtimesData() -> URL { sub("Runtimes") }
    public func rtp(_ family: RTPFamily) -> URL { sub("RTP").appending(path: family.rawValue, directoryHint: .isDirectory) }
    public func soundFonts() -> URL { sub("SoundFonts") }
    public func importStaging(txn: UUID) -> URL { sub("ImportStaging").appending(path: txn.uuidString, directoryHint: .isDirectory) }
    public func caches() -> URL { cachesRoot }

    /// `Logs/<game>/<session>/`; host-only sessions (no game) go under `Logs/host/`.
    public func logs(game: GameID?, session: UUID) -> URL {
        sub("Logs").appending(path: game?.description ?? "host", directoryHint: .isDirectory)
            .appending(path: session.uuidString, directoryHint: .isDirectory)
    }

    public func tier(_ tier: ContentTier, for game: GameID) -> URL {
        switch tier {
        case .original: self.game(game).appending(path: "Original", directoryHint: .isDirectory)
        case .overrides: self.game(game).appending(path: "Overrides", directoryHint: .isDirectory)
        case .generated: self.game(game).appending(path: "Generated", directoryHint: .isDirectory)
        case .saves: self.game(game).appending(path: "Saves", directoryHint: .isDirectory)
        case .artwork: self.game(game).appending(path: "Artwork", directoryHint: .isDirectory)
        case .persistent: self.game(game).appending(path: "Saves/persistent", directoryHint: .isDirectory)
        case .rtp: sub("RTP")
        case .runtimeCache: cachesRoot.appending(path: game.description, directoryHint: .isDirectory)
        case .importStaging: sub("ImportStaging")
        }
    }

    public func path(for kind: ContentKind, game: GameID) -> URL {
        let o = kind.ownership
        let base = tier(o.tier, for: game)
        return o.relativeDirectory.isEmpty ? base : base.appending(path: o.relativeDirectory, directoryHint: .isDirectory)
    }

    /// Directories excluded from device backup: game trees, runtimes, RTPs and staging (§15.2).
    public var backupExcluded: [URL] { [games(), runtimesData(), sub("RTP"), sub("ImportStaging")] }

    /// Creates the layout idempotently, marks the big trees as excluded from backup, and leaves the
    /// default data-protection class (`completeUntilFirstUserAuthentication`) so background work can read.
    public func ensureLayout(fileManager: FileManager = .default) throws {
        var dirs = [database().deletingLastPathComponent(), soundFonts(), sub("Logs"), cachesRoot, exportsRoot] + backupExcluded
        dirs += RTPFamily.allCases.map(rtp)
        for dir in dirs {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for var dir in backupExcluded {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try dir.setResourceValues(values)
        }
    }

    private func sub(_ name: String) -> URL { root.appending(path: name, directoryHint: .isDirectory) }
}
