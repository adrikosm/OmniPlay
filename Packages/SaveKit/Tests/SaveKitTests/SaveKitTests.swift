import Foundation
import GameCore
@testable import SaveKit
import Testing
import TestSupport

/// Saves are the only user data the app cannot regenerate: every write goes through the transaction,
/// so this is the one check that stands between a failed mutation and lost progress.
@Suite("SaveKit transaction")
struct SaveKitTests {
    @Test("Transaction swaps validated clones in and leaves files untouched when validation or the swap fails")
    func transaction() async throws {
        let root = try TemporaryGameRoot(name: "txn")
        defer { root.remove() }
        let paths = AppPaths(
            root: root.url.appending(path: "S"),
            cachesRoot: root.url.appending(path: "C"),
            exportsRoot: root.url.appending(path: "E")
        )
        let loc = SaveLocation.forGame(GameID(), paths: paths)
        let store = SaveFileStore(location: loc, fileExtension: "rpgsave")
        try store.write(Data("before".utf8), key: "file1")
        let target = try store.url(for: "file1")
        let txn = SafePersistTransaction(location: loc, identityHash: "h")

        let value = try await txn.run(targets: [target]) { staging in
            try Data("after".utf8).write(to: staging.url(for: target))
            return 42
        }
        #expect(value == 42)

        // A desktop Ren'Py save names `json` and `log` only past its 150 KB screenshot; the ZIP's tail lists them.
        let desktopSave = root.url.appending(path: "1-5-LT1.save")
        try (Data([0x50, 0x4B, 0x03, 0x04]) + Data(count: 150 << 10) + Data("json log".utf8)).write(to: desktopSave)
        #expect(SaveValidator.validate(file: desktopSave, family: .renpySave).format == .renpySave)
        #expect(try Data(contentsOf: target) == Data("after".utf8))

        await #expect(throws: PersistError.self) {
            try await txn.run(
                targets: [target],
                mutate: { staging in try Data("bad".utf8).write(to: staging.url(for: target)) },
                validate: { _ in throw CocoaError(.fileReadCorruptFile) }
            )
        }
        #expect(try Data(contentsOf: target) == Data("after".utf8))

        await #expect(throws: PersistError.self) {
            try await txn.run(
                targets: [target],
                mutate: { staging in try Data("newer".utf8).write(to: staging.url(for: target)) },
                verifyAfterReload: { throw CocoaError(.fileReadUnknown) }
            )
        }
        #expect(try Data(contentsOf: target) == Data("after".utf8))
        // Three transactions plus the restore that followed the failed verification.
        #expect(SaveVault.snapshots(location: loc).count == 4)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: loc.root.path(percentEncoded: false))) ?? [])
            .filter { $0.hasPrefix(".") }.isEmpty)

        try store.write(Data("incoming second".utf8), key: "file2")
        let snapshot = try await SaveVault.snapshot(location: loc, identityHash: "h", reason: .manualSnapshot)
        let snapshotDir = try #require(SaveVault.snapshots(location: loc).first { $0.manifest.id == snapshot.id }?.directory)
        try FileManager.default.removeItem(at: store.url(for: "file2"))
        try store.write(Data("live first".utf8), key: "file1")
        _ = try await SaveVault.restore(
            snapshot: snapshotDir,
            into: loc,
            identityHash: "h",
            mode: .stackIntoFreeSlots(slotPattern: "file%d.rpgsave")
        )
        #expect(try Data(contentsOf: target) == Data("live first".utf8))
        #expect(try Data(contentsOf: store.url(for: "file2")) == Data("incoming second".utf8))
        #expect(try Data(contentsOf: store.url(for: "file3")) == Data("after".utf8))
        await #expect(throws: RestoreError.self) {
            try await SaveVault.restore(snapshot: snapshotDir, into: loc, identityHash: "h", mode: .stackIntoFreeSlots(slotPattern: nil))
        }
        #expect(try Data(contentsOf: target) == Data("live first".utf8))
        #expect(try Data(contentsOf: store.url(for: "file2")) == Data("incoming second".utf8))
        #expect(SlotPattern("Save%02d.rvdata2")?.name(index: 3) == "Save03.rvdata2")
        for format in ["%d%s", "../%d", "%999999999d", "%@", "%d/%d"] {
            #expect(SlotPattern(format) == nil)
        }
        #expect(SlotNaming.duplicateName(for: "1-\(Int.max)-LT1.save", existing: [], pattern: nil) == nil)
        #expect(SlotNaming.duplicateName(for: "file\(Int.max).rpgsave", existing: [], pattern: "file%d.rpgsave") == nil)
        // A combining mark repeated by `c == dictSize` codes stays one grapheme while doubling; the cap counts units.
        #expect(BoundedDecode.lzStringBase64("oDANfGV07fwxTktW9HNez3f8GFHEmlnkWVXU2130A")?.utf16.count == 1035)
        let unicode = "{\"party\":\"e\u{301}😀\"}"
        #expect(BoundedDecode.lzStringBase64(LZString.compressToBase64(unicode)) == unicode)

        // Read real ZIP members, never deserialize Ren'Py's executable save payload.
        for (runtime, expected) in [("3661.9", "1:01:01" as String?), ("1e100", nil), ("-1", nil)] {
            let json = Data("{\"_save_name\":\"kept\",\"_game_runtime\":\(runtime)}".utf8)
            let save = try root.file("preview.save", Self.storedJSONZip(json))
            let preview = SavePreviewReader.renpy(save)
            #expect(preview?.title == "kept")
            #expect(preview?.playtime == expected)
        }
        try await verifyIncompleteBackupRefusal(loc)
    }

    private func verifyIncompleteBackupRefusal(_ location: SaveLocation) async throws {
        let fm = FileManager.default
        let saved = location.persistent.appending(path: "webLocalStorage/ls.a2V5.webstorage")
        try AtomicFileWriter.write(Data("kept".utf8), to: saved)
        let snapshot = try await SaveVault.snapshot(location: location, identityHash: "h", reason: .manualSnapshot)
        let dir = try #require(SaveVault.snapshots(location: location).first { $0.manifest.id == snapshot.id }?.directory)
        #expect(try SaveVault.validatedSnapshot(at: dir) == snapshot)
        let backupFile = dir.appending(path: "persistent/webLocalStorage/ls.a2V5.webstorage")
        try Data("corrupt".utf8).write(to: backupFile)
        await #expect(throws: RestoreError.invalidSnapshot) {
            try await SaveVault.restore(snapshot: dir, into: location, identityHash: "h", mode: .replace)
        }
        #expect(try Data(contentsOf: saved) == Data("kept".utf8))
        try fm.removeItem(at: backupFile)
        let store = try #require(PersistentStoreRegistry.stores(location: location, kinds: [.webLocalStorage]).first)
        await #expect(throws: RestoreError.invalidSnapshot) {
            try await PersistentStoreRegistry.restore(store, from: dir, location: location, identityHash: "h")
        }
        #expect(try Data(contentsOf: saved) == Data("kept".utf8))

        let locked = location.slots
        let mode = try fm.attributesOfItem(atPath: locked.path)[.posixPermissions]
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            if let mode {
                try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: locked.path)
            }
        }
        #expect(SaveVault.hasContent(location))
        #expect(throws: (any Error).self) { try LazyDirectoryWalker.walk(root: locked) { _ in .continue } }
        let before = try fm.contentsOfDirectory(atPath: location.backups.path).count
        await #expect(throws: (any Error).self) {
            try await SaveVault.snapshot(location: location, identityHash: "h", reason: .manualSnapshot)
        }
        #expect(try fm.contentsOfDirectory(atPath: location.backups.path).count == before)
        #expect(try Data(contentsOf: saved) == Data("kept".utf8))
    }

    private static func storedJSONZip(_ json: Data) -> Data {
        func little(_ value: Int, bytes: Int) -> Data {
            Data((0 ..< bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        let name = Data("json".utf8)
        var local = Data(repeating: 0, count: 30)
        local.replaceSubrange(0 ..< 4, with: little(0x0403_4B50, bytes: 4))
        local.replaceSubrange(26 ..< 28, with: little(name.count, bytes: 2))
        local += name + json
        var directory = Data(repeating: 0, count: 46)
        directory.replaceSubrange(0 ..< 4, with: little(0x0201_4B50, bytes: 4))
        directory.replaceSubrange(20 ..< 24, with: little(json.count, bytes: 4))
        directory.replaceSubrange(24 ..< 28, with: little(json.count, bytes: 4))
        directory.replaceSubrange(28 ..< 30, with: little(name.count, bytes: 2))
        directory += name
        var end = Data(repeating: 0, count: 22)
        end.replaceSubrange(0 ..< 4, with: little(0x0605_4B50, bytes: 4))
        end.replaceSubrange(10 ..< 12, with: little(1, bytes: 2))
        end.replaceSubrange(12 ..< 16, with: little(directory.count, bytes: 4))
        end.replaceSubrange(16 ..< 20, with: little(local.count, bytes: 4))
        return local + directory + end
    }
}
