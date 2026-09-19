import Foundation
import GameCore
import SaveKit
import Testing
import TestSupport

@Suite("SaveKit")
struct SaveKitTests {
    private func location() throws -> (SaveLocation, TemporaryGameRoot) {
        let root = try TemporaryGameRoot(name: "saves")
        let paths = AppPaths(
            root: root.url.appending(path: "S"),
            cachesRoot: root.url.appending(path: "C"),
            exportsRoot: root.url.appending(path: "E")
        )
        return (SaveLocation.forGame(GameID(), paths: paths), root)
    }

    @Test("Foreign saves are flagged by identity hash or imported origin")
    func foreignDetection() {
        let native = SaveProvenance(gameIdentityHash: "abc", origin: .native)
        #expect(!native.isForeign(to: "abc"))
        #expect(SaveProvenance(gameIdentityHash: "abc", origin: .imported).isForeign(to: "abc"))
        #expect(SaveProvenance(gameIdentityHash: "xyz", origin: .native).isForeign(to: "abc"))
    }

    @Test("Keys are constrained to a safe alphabet; colons become underscores")
    func keys() {
        #expect(SaveKey.validate("file1") == "file1")
        #expect(SaveKey.validate("ls.UlBHIEZpbGUx") == "ls.UlBHIEZpbGUx")
        #expect(SaveKey.validate("a:b") == "a_b")
        for key in ["RPG File1", "RPG Config", "ключ/с пробелом"] {
            let stem = SaveKey.encodeWebStorage(key)
            #expect(SaveKey.validate(stem) == stem, Comment(rawValue: stem))
            #expect(SaveKey.decodeWebStorage(stem) == key)
        }
        #expect(SaveKey.encodeWebStorage("RPG File1") == "ls.UlBHIEZpbGUx")
        for bad in ["", "../x", "a/b", "a b", String(repeating: "k", count: 129), "ключ"] {
            #expect(
                SaveKey.validate(bad) == nil,
                Comment(rawValue: bad)
            )
        }
    }

    @Test("Atomic writes replace files whole, leave no temp files, and stale temps are swept")
    func atomic() throws {
        let (loc, root) = try location()
        defer { root.remove() }
        let store = SaveFileStore(location: loc, fileExtension: "rpgsave")
        try store.write(Data("one".utf8), key: "file1")
        try store.write(Data("two".utf8), key: "file1")
        #expect(try store.read(key: "file1") == Data("two".utf8))
        #expect(store.keys().map(\.key) == ["file1"])
        try Data().write(to: loc.slots.appending(path: ".file2.rpgsave.part-abc"))
        #expect(AtomicFileWriter.sweepStale(in: loc.slots) == 1)
        #expect(throws: SaveFileStore.Failure.invalidKey("../x")) { try store.write(Data(), key: "../x") }
        #expect(throws: SaveFileStore.Failure.tooLarge(SaveFileStore.maxBytes + 1)) { try store.write(
            Data(count: SaveFileStore.maxBytes + 1),
            key: "big"
        ) }
        try store.remove(key: "file1")
        #expect(try store.read(key: "file1") == nil)
    }

    @Test("Snapshots clone slots and persistent data with a verifiable manifest; provenance is written once")
    func snapshot() async throws {
        let (loc, root) = try location()
        defer { root.remove() }
        let store = SaveFileStore(location: loc, fileExtension: "rmmzsave")
        try store.write(Data("save".utf8), key: "file1")
        try FileManager.default.createDirectory(at: loc.persistent, withIntermediateDirectories: true)
        try Data("cfg".utf8).write(to: loc.persistent.appending(path: "config.json"))
        let snap = try await SaveVault.snapshot(location: loc, identityHash: "h", reason: .beforeLaunch)
        #expect(snap.entries.map(\.relativePath) == ["persistent/config.json", "slots/file1.rmmzsave"])
        #expect(snap.checksum.count == 64)
        #expect(SaveVault.hasContent(loc))
        let listed = SaveVault.snapshots(location: loc)
        #expect(listed.count == 1 && listed[0].manifest == snap)
        #expect(try Data(contentsOf: listed[0].directory.appending(path: "slots/file1.rmmzsave")) == Data("save".utf8))
        _ = try await SaveVault.snapshot(location: loc, identityHash: "h", reason: .beforeLaunch)
        _ = try await SaveVault.snapshot(location: loc, identityHash: "h", reason: .manualSnapshot)
        #expect(SaveVault.prune(location: loc, keep: 1) == 1)
        #expect(SaveVault.snapshots(location: loc).count == 2)
        try SaveVault.writeProvenance(game: GameID(), titleHash: "h", engine: .rpgMakerMZ, location: loc)
        let first = try Data(contentsOf: loc.provenance)
        try SaveVault.writeProvenance(game: GameID(), titleHash: "other", engine: .renpy, location: loc)
        #expect(try Data(contentsOf: loc.provenance) == first)
    }
}
