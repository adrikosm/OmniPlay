import GameCore
import GRDB

public enum LibrarySort: Sendable, Hashable {
    case title, recentlyPlayed, recentlyImported

    var sql: String {
        switch self {
        case .title: "title COLLATE NOCASE"
        case .recentlyPlayed: "last_played_at DESC NULLS LAST, title COLLATE NOCASE"
        case .recentlyImported: "imported_at DESC"
        }
    }
}

/// A collection as the library's filter bar shows it.
public struct CollectionSummary: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let games: Int
}

public enum LibraryFilter: Sendable, Hashable {
    case all, favorites, hidden
    case engine(EngineFamily)
    /// One of the player's collections, by id.
    case collection(String)

    var request: QueryInterfaceRequest<GameRecord> {
        switch self {
        case .all: GameRecord.filter(sql: "hidden = 0")
        case .favorites: GameRecord.filter(sql: "hidden = 0 AND favorite = 1")
        case .hidden: GameRecord.filter(sql: "hidden = 1")
        case let .engine(e): GameRecord.filter(sql: "hidden = 0 AND engine = ?", arguments: [e.rawValue])
        case let .collection(id):
            GameRecord.filter(sql: "hidden = 0 AND id IN (SELECT game_id FROM collection_games WHERE collection_id = ?)", arguments: [id])
        }
    }
}

public extension GameStore {
    /// Emits the current tile list and every later change. Consumers hop to the main actor themselves.
    func observeLibrary(sort: LibrarySort = .title, filter: LibraryFilter = .all) -> AsyncValueObservation<[GameRecord]> {
        ValueObservation.tracking { db in try filter.request.order(sql: sort.sql).fetchAll(db) }.values(in: pool, scheduling: .task)
    }

    /// How many games each of All, Favourites and Hidden holds, for the library's filter bar.
    func observeCounts() -> AsyncValueObservation<[LibraryFilter: Int]> {
        ValueObservation.tracking { db in
            try Dictionary(uniqueKeysWithValues: [LibraryFilter.all, .favorites, .hidden].map { try ($0, $0.request.fetchCount(db)) })
        }.values(in: pool, scheduling: .task)
    }

    /// The player's collections by name, each with how many visible games it holds.
    func observeCollections() -> AsyncValueObservation<[CollectionSummary]> {
        ValueObservation.tracking { db in
            try Row.fetchAll(db, sql: """
            SELECT c.id, c.name, (SELECT COUNT(*) FROM collection_games cg JOIN games g ON g.id = cg.game_id
                                   WHERE cg.collection_id = c.id AND g.hidden = 0) AS games
            FROM collections c ORDER BY c.name COLLATE NOCASE
            """).map { CollectionSummary(id: $0["id"], name: $0["name"], games: $0["games"]) }
        }.values(in: pool, scheduling: .task)
    }

    func observeGame(id: GameID) -> AsyncValueObservation<GameRecord?> {
        ValueObservation.tracking { db in try GameRecord.fetchOne(db, key: id.description) }.values(in: pool, scheduling: .task)
    }
}
