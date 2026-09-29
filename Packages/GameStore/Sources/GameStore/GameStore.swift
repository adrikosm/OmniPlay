import Diagnostics
import Foundation
import GameCore
import GRDB

public struct GameStoreError: Error, CustomStringConvertible {
    public let operation: String
    public let underlying: Error
    public var description: String { "GameStore.\(operation): \(underlying)" }
}

/// The local library database: one `DatabasePool` (WAL) at `AppPaths.database()`. No raw SQL outside this package.
public final class GameStore: Sendable {
    public let pool: DatabasePool

    public static func open(paths: AppPaths) throws -> GameStore { try open(at: paths.database()) }

    public static func open(at url: URL) throws -> GameStore {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path(percentEncoded: false), configuration: config)
        return try GameStore(pool: pool)
    }

    public init(pool: DatabasePool) throws {
        self.pool = pool
        do { try Migrations.migrator.migrate(pool) } catch { throw GameStoreError(operation: "migrate", underlying: error) }
        OPLog.log(.filesystem, .info, "GameStore open at \(pool.path)")
    }

    func write<T: Sendable>(_ operation: String, _ body: @Sendable (Database) throws -> T) throws -> T {
        do { return try pool.write(body) } catch { throw GameStoreError(operation: operation, underlying: error) }
    }

    func read<T: Sendable>(_ operation: String, _ body: @Sendable (Database) throws -> T) throws -> T {
        do { return try pool.read(body) } catch { throw GameStoreError(operation: operation, underlying: error) }
    }

    // MARK: Generic operations for the metadata tables

    public func insert<R: AutoIDRecord>(_ record: R) throws -> R {
        try write("insert \(R.databaseTableName)") { try record.inserted($0) }
    }

    public func update<R: AutoIDRecord>(_ record: R) throws {
        try write("update \(R.databaseTableName)") { try record.update($0) }
    }

    public func save<R: StoreRecord>(_ record: R) throws {
        try write("save \(R.databaseTableName)") { try record.save($0) }
    }

    /// A game is visible only when its detection, runtime and import history all commit together.
    public func registerImport(
        game: GameRecord, detection: DetectionResultRecord, runtime: RuntimeSelectionRecord?,
        source: ImportRecord, replacing: Bool
    ) throws {
        try write("registerImport") { db in
            if replacing {
                try game.update(db)
            } else {
                try game.insert(db)
            }
            _ = try detection.inserted(db)
            if let runtime {
                _ = try runtime.inserted(db)
            }
            _ = try source.inserted(db)
        }
    }

    public func fetchAll<R: FetchableRecord & TableRecord & Sendable>(
        _: R.Type,
        game: GameID,
        limit: Int = 500,
        offset: Int = 0
    ) throws -> [R] {
        try read("fetch \(R.databaseTableName)") {
            try R.filter(sql: "game_id = ?", arguments: [game.description]).limit(limit, offset: offset).fetchAll($0)
        }
    }
}

// MARK: - Repositories

public extension GameStore {
    var games: Games { Games(store: self) }
    var detection: Detection { Detection(store: self) }
    var runtime: RuntimeSelections { RuntimeSelections(store: self) }
    var overrides: Overrides { Overrides(store: self) }
    var sessions: Sessions { Sessions(store: self) }
    var slots: Slots { Slots(store: self) }
    var imports: Imports { Imports(store: self) }
    var saves: Saves { Saves(store: self) }
    var persistentStores: PersistentStores { PersistentStores(store: self) }
    var mods: Mods { Mods(store: self) }
    var translations: Translations { Translations(store: self) }
    var collections: Collections { Collections(store: self) }

    /// The player's collections (UI-007). Names are unique regardless of case.
    struct Collections: Sendable {
        let store: GameStore

        @discardableResult
        public func create(name: String) throws -> String {
            let id = UUID().uuidString
            try store.write("collections.create") { db in
                try db.execute(sql: "INSERT INTO collections (id, name, created_at) VALUES (?, ?, ?)", arguments: [id, name, Date()])
            }
            return id
        }

        public func delete(id: String) throws {
            try store.write("collections.delete") { try $0.execute(sql: "DELETE FROM collections WHERE id = ?", arguments: [id]) }
        }

        public func set(_ game: GameID, in collection: String, member: Bool) throws {
            try store.write("collections.set") { db in
                if member {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO collection_games (collection_id, game_id) VALUES (?, ?)",
                        arguments: [collection, game.description]
                    )
                } else {
                    try db.execute(
                        sql: "DELETE FROM collection_games WHERE collection_id = ? AND game_id = ?",
                        arguments: [collection, game.description]
                    )
                }
            }
        }

        /// The collections a game is in.
        public func memberships(of game: GameID) throws -> Set<String> {
            try store.read("collections.memberships") { db in
                try Set(String.fetchAll(
                    db,
                    sql: "SELECT collection_id FROM collection_games WHERE game_id = ?",
                    arguments: [game.description]
                ))
            }
        }
    }

    /// Installed translation packs, one row per `Overrides/translations/<id>/` folder.
    struct Translations: Sendable {
        let store: GameStore
        public func fetch(game: GameID) throws -> [TranslationPackRecord] {
            try store.fetchAll(TranslationPackRecord.self, game: game).sorted { $0.priority > $1.priority }
        }

        public func save(_ pack: TranslationPackRecord) throws { try store.save(pack) }

        public func delete(id: String) throws {
            _ = try store.write("translations.delete") { try TranslationPackRecord.deleteOne($0, key: id) }
        }
    }

    /// Installed mods, one row per `Overrides/mods/<id>/` folder.
    struct Mods: Sendable {
        let store: GameStore
        public func fetch(game: GameID) throws -> [ModRecord] {
            try store.fetchAll(ModRecord.self, game: game).sorted { $0.priority > $1.priority }
        }

        public func save(_ mod: ModRecord) throws { try store.save(mod) }

        public func delete(id: String) throws {
            _ = try store.write("mods.delete") { try ModRecord.deleteOne($0, key: id) }
        }
    }

    /// The `persistent_stores` index, rebuilt with the saves after every session.
    struct PersistentStores: Sendable {
        let store: GameStore

        public func replaceAll(game: GameID, with records: [PersistentStoreRecord]) throws {
            try store.write("persistentStores.replaceAll") { db in
                try PersistentStoreRecord.filter(sql: "game_id = ?", arguments: [game.description]).deleteAll(db)
                for record in records {
                    _ = try record.inserted(db)
                }
            }
        }

        public func fetch(game: GameID) throws -> [PersistentStoreRecord] { try store.fetchAll(PersistentStoreRecord.self, game: game) }
    }

    /// The `saves_meta` index: one row per slot file, rebuilt from the file system after every session.
    struct Saves: Sendable {
        let store: GameStore

        public func replaceAll(game: GameID, with records: [SaveMetaRecord]) throws {
            try store.write("saves.replaceAll") { db in
                try SaveMetaRecord.filter(sql: "game_id = ?", arguments: [game.description]).deleteAll(db)
                for record in records {
                    _ = try record.inserted(db)
                }
            }
        }

        public func fetch(game: GameID) throws -> [SaveMetaRecord] { try store.fetchAll(SaveMetaRecord.self, game: game) }
    }

    struct Games: Sendable {
        let store: GameStore

        public func insert(_ game: GameRecord) throws { try store.write("games.insert") { try game.insert($0) } }
        public func update(_ game: GameRecord) throws { try store.write("games.update") { try game.update($0) } }
        @discardableResult
        public func delete(id: GameID) throws -> Bool { try store
            .write("games.delete") { try GameRecord.deleteOne($0, key: id.description) }
        }

        public func fetch(id: GameID) throws -> GameRecord? { try store.read("games.fetch") { try GameRecord.fetchOne(
            $0,
            key: id.description
        ) } }
        public func count() throws -> Int { try store.read("games.count") { try GameRecord.fetchCount($0) } }

        public func fetchAll(limit: Int = 200, offset: Int = 0) throws -> [GameRecord] {
            try store.read("games.fetchAll") { try GameRecord.order(sql: "title COLLATE NOCASE").limit(limit, offset: offset).fetchAll($0) }
        }

        /// FTS5 prefix search over titles: `"dra"` finds "Dragon Quest".
        public func search(_ query: String, limit: Int = 50) throws -> [GameRecord] {
            let tokens = query.split(whereSeparator: \.isWhitespace).map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }
            guard !tokens.isEmpty else { return [] }
            let match = tokens.joined(separator: " ")
            return try store.read("games.search") {
                try GameRecord.fetchAll($0, sql: """
                SELECT games.* FROM games JOIN games_fts ON games_fts.rowid = games.rowid
                WHERE games_fts MATCH ? AND games.hidden = 0 ORDER BY rank LIMIT ?
                """, arguments: [match, limit])
            }
        }
    }

    struct Detection: Sendable {
        let store: GameStore
        public func saveResult(_ result: DetectionResultRecord) throws -> DetectionResultRecord { try store.insert(result) }
        public func latest(for game: GameID) throws -> DetectionResultRecord? {
            try store.read("detection.latest") {
                try DetectionResultRecord.filter(sql: "game_id = ?", arguments: [game.description]).order(sql: "created_at DESC, id DESC")
                    .fetchOne($0)
            }
        }
    }

    struct RuntimeSelections: Sendable {
        let store: GameStore
        public func saveSelection(_ selection: RuntimeSelectionRecord) throws -> RuntimeSelectionRecord { try store.insert(selection) }
        public func latest(for game: GameID) throws -> RuntimeSelectionRecord? {
            try store.read("runtime.latest") {
                try RuntimeSelectionRecord.filter(sql: "game_id = ?", arguments: [game.description]).order(sql: "created_at DESC, id DESC")
                    .fetchOne($0)
            }
        }
    }

    struct Overrides: Sendable {
        let store: GameStore
        public func set(game: GameID, key: String, valueJson: String) throws {
            try store.save(OverrideRecord(gameId: game, key: key, valueJson: valueJson))
        }

        public func get(game: GameID, key: String) throws -> String? {
            try store.read("overrides.get") { try OverrideRecord.fetchOne($0, key: ["game_id": game.description, "key": key])?.valueJson }
        }

        public func all(game: GameID) throws -> [OverrideRecord] { try store.fetchAll(OverrideRecord.self, game: game) }
    }

    struct Sessions: Sendable {
        let store: GameStore
        public func begin(_ session: SessionRecord) throws { try store.write("sessions.begin") { try session.insert($0) } }
        public func end(id: UUID, verdict: String, grade: PlayabilityGrade?, peakFootprint: Int64?, notes: String? = nil) throws {
            try store.write("sessions.end") { db in
                guard var s = try SessionRecord.fetchOne(db, key: id.uuidString) else { return }
                s.endedAt = .now
                s.teardownVerdict = verdict
                s.grade = grade
                s.peakFootprint = peakFootprint
                s.notes = notes
                try s.update(db)
            }
        }

        public func fetch(id: UUID) throws -> SessionRecord? { try store.read("sessions.fetch") { try SessionRecord.fetchOne(
            $0,
            key: id.uuidString
        ) } }

        /// A game's sessions, newest first (served by the `sessions_game` index).
        public func recent(game: GameID, limit: Int = 500) throws -> [SessionRecord] {
            try store.read("sessions.recent") {
                try SessionRecord.filter(sql: "game_id = ?", arguments: [game.description]).order(sql: "started_at DESC")
                    .limit(limit).fetchAll($0)
            }
        }
    }

    struct Slots: Sendable {
        let store: GameStore
        public func markSpent(bootID: String, slot: SessionSlot, by game: GameID?) throws {
            try store.save(SlotLedgerRecord(processBootId: bootID, slot: slot, spent: true, spentByGame: game))
        }

        public func spent(bootID: String) throws -> Set<SessionSlot> {
            try store.read("slots.spent") {
                try Set(SlotLedgerRecord.filter(sql: "process_boot_id = ? AND spent = 1", arguments: [bootID]).fetchAll($0).map(\.slot))
            }
        }

        /// Drops every other boot's rows: a new process starts with fresh slots.
        public func reset(bootID: String) throws {
            _ = try store
                .write("slots.reset") { try SlotLedgerRecord.filter(sql: "process_boot_id <> ?", arguments: [bootID]).deleteAll($0) }
        }
    }

    struct Imports: Sendable {
        let store: GameStore
        public func record(_ record: ImportRecord) throws -> ImportRecord { try store.insert(record) }
        public func recent(limit: Int = 50) throws -> [ImportRecord] {
            try store.read("imports.recent") { try ImportRecord.order(sql: "created_at DESC, id DESC").limit(limit).fetchAll($0) }
        }

        /// One game's imports, newest first.
        public func recent(game: GameID, limit: Int = 500) throws -> [ImportRecord] {
            try store.read("imports.recentForGame") {
                try ImportRecord.filter(sql: "game_id = ?", arguments: [game.description]).order(sql: "created_at DESC, id DESC")
                    .limit(limit).fetchAll($0)
            }
        }

        public func find(sha256: String) throws -> [ImportRecord] {
            try store.read("imports.find") { try ImportRecord.filter(sql: "source_sha256 = ?", arguments: [sha256]).fetchAll($0) }
        }
    }
}
