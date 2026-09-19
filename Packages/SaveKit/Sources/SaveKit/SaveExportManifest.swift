import Foundation
import GameCore

/// `omniplay-save-manifest.json` inside an exported ZIP: enough to recognise the title on import and verify files.
public struct SaveExportManifest: Codable, Sendable, Hashable {
    public static let fileName = "omniplay-save-manifest.json"
    public var formatVersion = 1
    public let engine: EngineFamily
    public let family: SaveFamily
    public let gameID: GameID
    public let titleHash: String
    public let title: String
    public let exportedAt: Date
    public let entries: [SaveEntry]

    public init(
        engine: EngineFamily,
        family: SaveFamily,
        gameID: GameID,
        titleHash: String,
        title: String,
        exportedAt: Date = .now,
        entries: [SaveEntry]
    ) {
        self.engine = engine
        self.family = family
        self.gameID = gameID
        self.titleHash = titleHash
        self.title = title
        self.exportedAt = exportedAt
        self.entries = entries
    }

    /// Hashes every file under `slots/` and `persistent/` of a save location.
    public static func entries(for location: SaveLocation) throws -> [SaveEntry] {
        var entries: [SaveEntry] = []
        for (dir, name) in [(location.slots, "slots"), (location.persistent, "persistent")]
            where FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)) {
            var files: [RelativeEntry] = []
            try LazyDirectoryWalker.walk(root: dir) { entry in
                if !entry.isDirectory, !entry.url.lastPathComponent.hasPrefix(".") {
                    files.append(entry)
                }
                return .continue
            }
            for file in files {
                try entries.append(SaveEntry(
                    relativePath: "\(name)/\(file.relativePath)",
                    bytes: file.fileSize,
                    sha256: StreamingHasher.sha256(of: file.url).hex
                ))
            }
        }
        return entries.sorted { $0.relativePath < $1.relativePath }
    }
}
