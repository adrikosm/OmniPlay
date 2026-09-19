import Foundation

/// Where a save came from. Cross-title loads and externally imported saves get a distinctly stronger warning:
/// `Marshal.load` / `pickle.loads` on a foreign save is the realistic attack surface. Saves are never signed against the user.
public struct SaveProvenance: Codable, Sendable, Hashable {
    public enum Origin: String, Codable,
        Sendable { case native, imported, preModBackup, preCheatBackup, manualSnapshot, beforeLaunch, crash }

    /// `GameDescriptor.identityHash` of the title that produced the save.
    public let gameIdentityHash: String
    public let origin: Origin
    public let createdAt: Date

    public init(gameIdentityHash: String, origin: Origin, createdAt: Date = .now) {
        self.gameIdentityHash = gameIdentityHash
        self.origin = origin
        self.createdAt = createdAt
    }

    /// True when this save should carry the stronger foreign-content warning.
    public func isForeign(to identityHash: String) -> Bool {
        gameIdentityHash != identityHash || origin == .imported
    }
}

/// One file inside a snapshot.
public struct SaveEntry: Codable, Sendable, Hashable {
    public let relativePath: String
    public let bytes: Int64
    public let sha256: String
}

/// A timestamped copy of `Saves/slots` and `Saves/persistent`, cloned into `Saves/backups/<timestamp>/` with this manifest.
public struct SaveSnapshot: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let provenance: SaveProvenance
    public let entries: [SaveEntry]
    /// SHA-256 over the entry hashes in path order, hex.
    public let checksum: String

    public init(id: UUID = UUID(), timestamp: Date = .now, provenance: SaveProvenance, entries: [SaveEntry], checksum: String) {
        self.id = id
        self.timestamp = timestamp
        self.provenance = provenance
        self.entries = entries
        self.checksum = checksum
    }

    public var files: [String] { entries.map(\.relativePath) }
}
