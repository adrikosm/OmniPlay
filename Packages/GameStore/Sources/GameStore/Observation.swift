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

public enum LibraryFilter: Sendable, Hashable {
    case all, favorites, hidden
    case engine(EngineFamily)

    var request: QueryInterfaceRequest<GameRecord> {
        switch self {
        case .all: GameRecord.filter(sql: "hidden = 0")
        case .favorites: GameRecord.filter(sql: "hidden = 0 AND favorite = 1")
        case .hidden: GameRecord.filter(sql: "hidden = 1")
        case let .engine(e): GameRecord.filter(sql: "hidden = 0 AND engine = ?", arguments: [e.rawValue])
        }
    }
}

public extension GameStore {
    /// Emits the current tile list and every later change. Consumers hop to the main actor themselves.
    func observeLibrary(sort: LibrarySort = .title, filter: LibraryFilter = .all) -> AsyncValueObservation<[GameRecord]> {
        ValueObservation.tracking { db in try filter.request.order(sql: sort.sql).fetchAll(db) }.values(in: pool, scheduling: .task)
    }

    func observeGame(id: GameID) -> AsyncValueObservation<GameRecord?> {
        ValueObservation.tracking { db in try GameRecord.fetchOne(db, key: id.description) }.values(in: pool, scheduling: .task)
    }
}
