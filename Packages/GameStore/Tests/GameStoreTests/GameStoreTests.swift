import Foundation
import GameCore
import GameStore
import Testing
import TestSupport

@Suite("GameStore", .serialized)
struct GameStoreTests {
    /// The temporary root must outlive the store: `defer { f.root.remove() }` in each test keeps it alive.
    private struct Fixture { let store: GameStore; let root: TemporaryGameRoot }
    private func openStore() throws -> Fixture {
        let root = try TemporaryGameRoot(name: "store")
        return try Fixture(store: GameStore.open(at: root.url.appending(path: "Database/omniplay.sqlite")), root: root)
    }

    @Test("Schema v1 migrates on an empty database and again on an existing one")
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
    }

    @Test("FTS finds a game by partial title after insert, update and not after delete")
    func fts() throws {
        let f = try openStore()
        defer { f.root.remove() }
        let store = f.store
        let g = GameRecord(title: "Dragon Fantasy Legend", engine: .rpgMakerVXAce)
        try store.games.insert(g)
        #expect(try store.games.search("dra").map(\.id) == [g.id])
        #expect(try store.games.search("fant leg").map(\.id) == [g.id])
        #expect(try store.games.search("zelda").isEmpty)
        var renamed = g
        renamed.title = "Zelda-like"
        try store.games.update(renamed)
        #expect(try store.games.search("zelda").count == 1)
        try store.games.delete(id: g.id)
        #expect(try store.games.search("zelda").isEmpty)
        #expect(try store.games.count() == 0)
    }

    @Test("Every record type round-trips through its table")
    func crud() throws {
        let f = try openStore()
        defer { f.root.remove() }
        let store = f.store
        var g = GameRecord(title: "Round Trip", engine: .renpy)
        g.runtime = .renpy(engine: .v853)
        g.manualRuntimeOverride = .renpy(engine: .v837)
        g.compatProfileJson = CompatibilityProfile(overrides: ["web.loadMode": "server"])
        g.compatibilityState = .playable
        g.importedAt = Date(timeIntervalSince1970: 1_800_000_000) // whole seconds: the column keeps milliseconds
        try store.games.insert(g)
        let fetched = try store.games.fetch(id: g.id)
        #expect(fetched == g)

        let det = try store.detection.saveResult(.init(
            gameId: g.id,
            outcome: "renpy",
            confidence: 0.97,
            evidence: [.init(check: "vc_version", outcome: "8.5.3", weight: 0.9)],
            detectorVersions: ["renpy": "1"]
        ))
        #expect(det.id != nil)
        #expect(try store.detection.latest(for: g.id)?.evidenceJson.first?.check == "vc_version")

        _ = try store.runtime.saveSelection(.init(
            gameId: g.id,
            selectedRuntime: .renpy(engine: .v853),
            reason: "version bucket",
            warnings: ["w"],
            fallbacks: [.renpy(engine: .v837)]
        ))
        #expect(try store.runtime.latest(for: g.id)?.fallbacksJson == [.renpy(engine: .v837)])

        try store.save(CompatProfileRecord(id: "p1", gameId: g.id, json: .init(overrides: ["a": "b"])))
        #expect(try store.fetchAll(CompatProfileRecord.self, game: g.id).first?.json.overrides["a"] == "b")

        let sid = UUID()
        try store.sessions.begin(SessionRecord(id: sid, gameId: g.id, runtime: .renpy(engine: .v853)))
        try store.sessions.end(id: sid, verdict: "clean", grade: .ingame, peakFootprint: 512 << 20)
        let s = try store.sessions.fetch(id: sid)
        #expect(s?.slot == .renpy853)
        #expect(s?.grade == .ingame)
        #expect(s?.endedAt != nil)

        try store.games.delete(id: g.id)
        #expect(try store.detection.latest(for: g.id) == nil) // cascade
    }

    @Test("Metadata tables round-trip through the generic operations")
    func metadataTables() throws {
        let f = try openStore()
        defer { f.root.remove() }
        let store = f.store
        let g = GameRecord(title: "Meta", engine: .renpy)
        try store.games.insert(g)
        let imp = try store.imports.record(.init(
            gameId: g.id,
            sourceName: "game.zip",
            container: "zip",
            sourceSha256: "ff",
            bytes: 10,
            outcome: "ok"
        ))
        #expect(imp.id != nil)
        #expect(try store.imports.find(sha256: "ff").count == 1)
        #expect(try store.imports.recent().first?.sourceName == "game.zip")

        _ = try store.insert(MediaJobRecord(
            gameId: g.id,
            inputRel: "movies/a.webm",
            outputRel: "movies/a.mp4",
            sourceCodec: "vp9",
            targetCodec: "h264",
            targetRuntime: "web",
            reason: "no vp9",
            state: "queued"
        ))
        _ = try store.insert(SaveMetaRecord(
            gameId: g.id,
            slotKey: "1",
            relPath: "slots/1.save",
            family: "renpy",
            bytes: 1,
            modifiedAt: .now,
            provenanceHash: "h"
        ))
        _ = try store.insert(PersistentStoreRecord(gameId: g.id, kind: "persistent", relPath: "persistent", bytes: 2, modifiedAt: .now))
        #expect(try store.fetchAll(MediaJobRecord.self, game: g.id).count == 1)
        #expect(try store.fetchAll(SaveMetaRecord.self, game: g.id).first?.slotKey == "1")
        #expect(try store.fetchAll(PersistentStoreRecord.self, game: g.id).count == 1)
    }

    @Test("Mods, translations and overrides round-trip and cascade on delete")
    func modsAndOverrides() throws {
        let f = try openStore()
        defer { f.root.remove() }
        let store = f.store
        let g = GameRecord(title: "Mods", engine: .renpy)
        try store.games.insert(g)
        try store.save(ModRecord(id: "m1", gameId: g.id, name: "Mod", source: "local", contentType: "overlay"))
        try store.save(TranslationPackRecord(
            id: "t1",
            gameId: g.id,
            name: "EN",
            source: "local",
            contentType: "overlay",
            format: "rpy",
            language: "en"
        ))
        #expect(try store.fetchAll(ModRecord.self, game: g.id).first?.id == "m1")
        #expect(try store.fetchAll(TranslationPackRecord.self, game: g.id).first?.language == "en")

        try store.overrides.set(game: g.id, key: "ruby", valueJson: "\"ruby31\"")
        try store.overrides.set(game: g.id, key: "ruby", valueJson: "\"ruby19\"")
        #expect(try store.overrides.get(game: g.id, key: "ruby") == "\"ruby19\"")
        #expect(try store.overrides.all(game: g.id).count == 1)

        // Cascade: deleting the game removes its dependent rows.
        try store.games.delete(id: g.id)
        #expect(try store.fetchAll(ModRecord.self, game: g.id).isEmpty)
    }

    @Test("Slot ledger is scoped to a process boot id")
    func slotLedger() throws {
        let f = try openStore()
        defer { f.root.remove() }
        let store = f.store
        try store.slots.markSpent(bootID: "boot-1", slot: .ruby18, by: nil)
        try store.slots.markSpent(bootID: "boot-1", slot: .renpy853, by: GameID())
        #expect(try store.slots.spent(bootID: "boot-1") == [.ruby18, .renpy853])
        try store.slots.reset(bootID: "boot-2")
        #expect(try store.slots.spent(bootID: "boot-1").isEmpty)
        #expect(try store.slots.spent(bootID: "boot-2").isEmpty)
    }

    @Test("Library observation yields on insert, update and delete")
    func observation() async throws {
        let f = try openStore()
        defer { f.root.remove() }
        let store = f.store
        var it = store.observeLibrary(sort: .recentlyImported).makeAsyncIterator()
        #expect(try await it.next() == [])
        let a = GameRecord(title: "A", engine: .html5)
        try store.games.insert(a)
        #expect(try await it.next()?.map(\.title) == ["A"])
        var hidden = a
        hidden.hidden = true
        try store.games.update(hidden)
        #expect(try await it.next() == [])
        var single = store.observeGame(id: a.id).makeAsyncIterator()
        #expect(try await single.next()??.hidden == true)
        try store.games.delete(id: a.id)
        #expect(try await single.next() == .some(nil))
    }

    @Test("Filters and sorts shape the observed list")
    func filters() async throws {
        let f = try openStore()
        defer { f.root.remove() }
        let store = f.store
        var fav = GameRecord(title: "Fav", engine: .rpgMakerMV)
        fav.favorite = true
        try store.games.insert(fav)
        try store.games.insert(GameRecord(title: "Other", engine: .renpy))
        var favorites = store.observeLibrary(filter: .favorites).makeAsyncIterator()
        #expect(try await favorites.next()?.map(\.title) == ["Fav"])
        var mv = store.observeLibrary(filter: .engine(.rpgMakerMV)).makeAsyncIterator()
        #expect(try await mv.next()?.count == 1)
        #expect(try store.games.fetchAll().map(\.title) == ["Fav", "Other"])
    }
}
