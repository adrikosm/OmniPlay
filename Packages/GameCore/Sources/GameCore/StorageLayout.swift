import Foundation

/// On-device storage layout (design authority §15.2). Everything lives under
/// `Application Support/OmniPlay/`; game trees are `isExcludedFromBackup`.
public struct StorageLayout: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func applicationDefault(fileManager: FileManager = .default) throws -> StorageLayout {
        let base = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return StorageLayout(root: base.appending(path: "OmniPlay", directoryHint: .isDirectory))
    }

    public var databaseDirectory: URL { dir("Database") }
    public var databaseFile: URL { databaseDirectory.appending(path: "omniplay.sqlite") }
    public var gamesDirectory: URL { dir("Games") }
    public var runtimesDirectory: URL { dir("Runtimes") }
    public var rtpDirectory: URL { dir("RTP") }
    public var soundFontsDirectory: URL { dir("SoundFonts") }
    public var importStagingDirectory: URL { dir("ImportStaging") }
    public var logsDirectory: URL { dir("Logs") }

    public func rtp(_ family: RTPFamily) -> URL {
        rtpDirectory.appending(path: family.rawValue, directoryHint: .isDirectory)
    }

    public func game(_ id: UUID) -> GameDirectories {
        GameDirectories(root: gamesDirectory.appending(path: id.uuidString, directoryHint: .isDirectory))
    }

    public func importStaging(transaction: UUID) -> URL {
        importStagingDirectory.appending(path: transaction.uuidString, directoryHint: .isDirectory)
    }

    public func logs(game: UUID, session: UUID) -> URL {
        logsDirectory
            .appending(path: game.uuidString, directoryHint: .isDirectory)
            .appending(path: session.uuidString, directoryHint: .isDirectory)
    }

    /// Directories that must exist before first use. Game trees are created per import transaction.
    public var requiredDirectories: [URL] {
        [
            databaseDirectory,
            gamesDirectory,
            runtimesDirectory,
            rtpDirectory,
            soundFontsDirectory,
            importStagingDirectory,
            logsDirectory,
        ] + RTPFamily.allCases.map(rtp)
    }

    private func dir(_ name: String) -> URL {
        root.appending(path: name, directoryHint: .isDirectory)
    }
}

/// User-imported RTPs only; OmniPlay never bundles Enterbrain/Kadokawa assets.
public enum RTPFamily: String, CaseIterable, Sendable, Codable {
    case xp = "XP"
    case vx = "VX"
    case vxAce = "VXAce"
    case rpg2000 = "RPG2000"
    case rpg2003 = "RPG2003"
}

/// One game's tree. `Original/` is write-once; everything else is an overlay.
public struct GameDirectories: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var original: URL { root.appending(path: "Original", directoryHint: .isDirectory) }
    public var overrides: URL { root.appending(path: "Overrides", directoryHint: .isDirectory) }
    public var generated: URL { root.appending(path: "Generated", directoryHint: .isDirectory) }
    public var saves: URL { root.appending(path: "Saves", directoryHint: .isDirectory) }
    public var artwork: URL { root.appending(path: "Artwork", directoryHint: .isDirectory) }
    /// Case-insensitive path index (§13.4).
    public var indexFile: URL { root.appending(path: "index.json") }
    /// Detection evidence, chosen runtime, media probe, loopback port.
    public var manifestFile: URL { root.appending(path: "game.json") }

    /// The directory backing one resolution tier, or nil for `.rtp` when no RTP applies.
    public func directory(for tier: ResolutionTier, rtp: URL? = nil) -> URL? {
        switch tier {
        case .overrides: overrides
        case .generated: generated
        case .original: original
        case .rtp: rtp
        }
    }
}

/// Overlay VFS resolution order: `Overrides/ → Generated/ → Original/ → RTP/` (§1.3, §15.2).
public enum ResolutionTier: Int, CaseIterable, Sendable, Comparable {
    case overrides
    case generated
    case original
    case rtp

    public static let resolutionOrder: [ResolutionTier] = allCases

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
