import Foundation
import GameCore
import GameStore
import Testing
import TestSupport

/// A migration that goes wrong takes the whole library with it, and the failure is silent until
/// the next launch, so the schema shape is asserted on both a fresh and an existing database.
@Suite("GameStore", .serialized)
struct GameStoreTests {
    @Test("The schema (v1, v2) migrates on an empty database and again on an existing one")
    func migrates() throws {
        let root = try TemporaryGameRoot(name: "migrate")
        let url = root.url.appending(path: "omniplay.sqlite")
        _ = try GameStore.open(at: url)
        let again = try GameStore.open(at: url)
        let tables = try again.pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'games_fts%' ORDER BY name
                """
            )
        }
        #expect(tables == [
            "collection_games",
            "collections",
            "compat_profiles",
            "detection_results",
            "games",
            "grdb_migrations",
            "import_records",
            "media_jobs",
            "mods",
            "overrides_ledger",
            "persistent_stores",
            "runtime_selections",
            "saves_meta",
            "sessions",
            "slot_ledger",
            "translation_packs",
        ])
        let visible = GameRecord(title: "Search visible", engine: .html5)
        var hidden = GameRecord(title: "Search hidden", engine: .html5)
        hidden.hidden = true
        try again.games.insert(visible)
        try again.games.insert(hidden)
        #expect(try again.games.search("Search").map(\.id) == [visible.id])
        #expect(try again.games.search("hidden").isEmpty)
        #expect(try again.games.search("   ").isEmpty)
        #expect(try again.games.fetch(id: hidden.id)?.hidden == true)
    }
}
