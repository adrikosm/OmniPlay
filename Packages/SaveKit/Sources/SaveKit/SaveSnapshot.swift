import Foundation

/// Where a save came from. Cross-title loads and externally imported saves get a distinctly
/// stronger warning: `Marshal.load` / `pickle.loads` on a foreign save is the realistic attack
/// surface (design authority §15.1). Saves are never cryptographically signed against the user.
public struct SaveProvenance: Codable, Sendable, Hashable {
    public enum Origin: String, Codable, Sendable {
        case native
        case imported
        case preModBackup
        case preCheatBackup
        case manualSnapshot
    }

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

/// A timestamped copy of everything under `Games/<UUID>/Saves/`. Written atomically (write-and-rename)
/// with a checksum; exported as ZIP only (never RAR — licence).
public struct SaveSnapshot: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let provenance: SaveProvenance
    /// Relative paths inside `Saves/`.
    public let files: [String]
    /// SHA-256 over the snapshot's file contents in `files` order, hex.
    public let checksum: String

    public init(id: UUID = UUID(), provenance: SaveProvenance, files: [String], checksum: String) {
        self.id = id
        self.provenance = provenance
        self.files = files
        self.checksum = checksum
    }
}
