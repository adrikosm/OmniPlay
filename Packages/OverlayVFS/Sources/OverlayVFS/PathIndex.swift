import Diagnostics
import Foundation
import GameCore
import GRDB

/// Lookup key for a logical path: `\` → `/`, no leading slash, NFC, lower-cased. iOS APFS is case-sensitive;
/// games authored on Windows are not, so every lookup goes through this key.
public enum PathKey {
    public static func normalize(_ path: String) -> String {
        var p = path.replacingOccurrences(of: "\\", with: "/")
        while p.hasPrefix("/") {
            p.removeFirst()
        }
        while p.hasSuffix("/") {
            p.removeLast()
        }
        return p.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// The key of the directory containing `key` (`""` for the root).
    public static func parent(of key: String) -> String {
        guard let slash = key.lastIndex(of: "/") else { return "" }
        return String(key[..<slash])
    }
}

public struct IndexedEntry: Sendable, Hashable, Codable, FetchableRecord {
    public let layer: String
    public let key: String
    public let realRel: String
    public let isDir: Bool
    public let size: Int64
}

public struct Collision: Sendable, Hashable, Codable, FetchableRecord {
    public let layer: String
    public let key: String
    public let keptReal: String
    public let droppedReal: String
}

/// Per-game case-insensitive index at `Games/<id>/index.sqlite`, separate from the library database so
/// it can be deleted and rebuilt independently. Layers are named (`original`, `generated`, `overrides/mods/x`).
public final class PathIndex: Sendable {
    public static let schemaVersion = 1
    public static let batchSize = 500
    public let url: URL
    let queue: DatabaseQueue

    public static func open(at url: URL) throws -> PathIndex {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            return try PathIndex(url: url)
        } catch {
            // Corrupt or foreign file: start over, the index is derived data.
            OPLog.log(.filesystem, .error, "path index unreadable, rebuilding: \(error)")
            try? FileManager.default.removeItem(at: url)
            return try PathIndex(url: url)
        }
    }

    private init(url: URL) throws {
        self.url = url
        queue = try DatabaseQueue(path: url.path(percentEncoded: false))
        try queue.write { db in
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            if version != Self.schemaVersion {
                try db.execute(sql: """
                DROP TABLE IF EXISTS entries; DROP TABLE IF EXISTS collisions;
                CREATE TABLE entries (layer TEXT NOT NULL, key TEXT NOT NULL, real_rel TEXT NOT NULL, is_dir INTEGER NOT NULL,
                                      size INTEGER NOT NULL, PRIMARY KEY (layer, key)) WITHOUT ROWID;
                CREATE TABLE collisions (layer TEXT NOT NULL, key TEXT NOT NULL, kept_real TEXT NOT NULL, dropped_real TEXT NOT NULL);
                PRAGMA user_version = \(Self.schemaVersion);
                """)
            }
        }
    }

    public func lookup(layer: String, key: String) throws -> IndexedEntry? {
        try queue.read { db in
            try IndexedEntry.fetchOne(
                db,
                sql: "SELECT layer, key, real_rel AS realRel, is_dir AS isDir, size FROM entries WHERE layer = ? AND key = ?",
                arguments: [layer, key]
            )
        }
    }

    /// SQLite's backup API includes committed WAL pages and uses bounded page buffers.
    public func backup(to destination: URL) throws {
        try queue.backup(to: DatabaseQueue(path: destination.path(percentEncoded: false)))
    }

    /// Direct children of `directoryKey` (`""` for the layer root), paged.
    public func children(layer: String, directoryKey: String, limit: Int = 500, offset: Int = 0) throws -> [IndexedEntry] {
        // The directory name is literal: `audio/[se]` must not become a GLOB character class.
        let prefix = directoryKey.isEmpty ? "" : Self.globLiteral(directoryKey) + "/"
        return try queue.read { db in
            try IndexedEntry.fetchAll(db, sql: """
            SELECT layer, key, real_rel AS realRel, is_dir AS isDir, size FROM entries
            WHERE layer = ? AND key GLOB ? AND key NOT GLOB ? AND key <> ? ORDER BY key LIMIT ? OFFSET ?
            """, arguments: [layer, prefix + "*", prefix + "*/*", directoryKey, limit, offset])
        }
    }

    /// `s` as a GLOB pattern that matches only itself: `*`, `?` and `[` become one-character classes.
    static func globLiteral(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "*", "?", "[": out += "[\(c)]"
            default: out.append(c)
            }
        }
        return out
    }

    /// Keys matching a SQLite GLOB pattern (case-sensitive on lower-cased keys), at most `limit`.
    public func glob(layer: String, pattern: String, limit: Int = 64) throws -> [IndexedEntry] {
        try queue.read { db in
            try IndexedEntry.fetchAll(db, sql: """
            SELECT layer, key, real_rel AS realRel, is_dir AS isDir, size FROM entries WHERE layer = ? AND key GLOB ? ORDER BY key LIMIT ?
            """, arguments: [layer, pattern, limit])
        }
    }

    public func layers() throws -> [String] { try queue.read { try String.fetchAll(
        $0,
        sql: "SELECT DISTINCT layer FROM entries ORDER BY layer"
    ) } }
    public func count(layer: String) throws -> Int { try queue.read { try Int.fetchOne(
        $0,
        sql: "SELECT COUNT(*) FROM entries WHERE layer = ?",
        arguments: [layer]
    ) ?? 0 } }
    public func collisions(layer: String) throws -> [Collision] {
        try queue.read { try Collision.fetchAll(
            $0,
            sql: "SELECT layer, key, kept_real AS keptReal, dropped_real AS droppedReal FROM collisions WHERE layer = ?",
            arguments: [layer]
        ) }
    }

    public func upsert(layer: String, relativePath: String, isDirectory: Bool, size: Int64) throws {
        try queue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO entries (layer, key, real_rel, is_dir, size) VALUES (?, ?, ?, ?, ?)",
                arguments: [layer, PathKey.normalize(relativePath), relativePath, isDirectory, size]
            )
        }
    }

    public func remove(layer: String, relativePath: String) throws {
        try queue.write { try $0.execute(
            sql: "DELETE FROM entries WHERE layer = ? AND key = ?",
            arguments: [layer, PathKey.normalize(relativePath)]
        ) }
    }

    public func invalidate(layer: String) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM entries WHERE layer = ?", arguments: [layer])
            try db.execute(sql: "DELETE FROM collisions WHERE layer = ?", arguments: [layer])
        }
    }

    public func rebuild(layer: String, root: URL) throws {
        try invalidate(layer: layer)
        try build(layer: layer, root: root)
    }

    /// Streams the tree into the index, 500 rows per transaction. Case-only collisions keep the first entry
    /// (walk order) and are recorded. Cancel the surrounding Task to abort between batches.
    public func build(layer: String, root: URL) throws {
        struct Row { let key: String, real: String, isDir: Bool, size: Int64 }
        var batch: [Row] = []
        batch.reserveCapacity(Self.batchSize)
        func flush() throws {
            guard !batch.isEmpty else { return }
            try Task.checkCancellation()
            try queue.write { db in
                for row in batch {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO entries (layer, key, real_rel, is_dir, size) VALUES (?, ?, ?, ?, ?)",
                        arguments: [layer, row.key, row.real, row.isDir, row.size]
                    )
                    if db.changesCount == 0, let kept = try String.fetchOne(
                        db,
                        sql: "SELECT real_rel FROM entries WHERE layer = ? AND key = ?",
                        arguments: [layer, row.key]
                    ), kept != row.real {
                        try db.execute(
                            sql: "INSERT INTO collisions (layer, key, kept_real, dropped_real) VALUES (?, ?, ?, ?)",
                            arguments: [layer, row.key, kept, row.real]
                        )
                        OPLog.log(.filesystem, .default, "case collision in \(layer): kept \(kept), dropped \(row.real)")
                    }
                }
            }
            batch.removeAll(keepingCapacity: true)
        }
        try LazyDirectoryWalker.walk(root: root) { entry in
            batch.append(Row(
                key: PathKey.normalize(entry.relativePath),
                real: entry.relativePath,
                isDir: entry.isDirectory,
                size: entry.fileSize
            ))
            if batch.count >= Self.batchSize {
                try flush()
            }
            return .continue
        }
        try flush()
    }
}
