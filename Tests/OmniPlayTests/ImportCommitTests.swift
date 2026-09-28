import Diagnostics
import Foundation
import GameCore
import GameImport
import GameStore
@testable import OmniPlay
import OverlayVFS
import RuntimeCore
import SaveKit
import Testing
import WebKit

/// The whole import path in one go: a failure mid-commit has to leave the library, the files and the
/// index exactly as they were, and a successful replacement has to keep the player's saves.
@Suite("Import commit rollback")
struct ImportCommitTests {
    @Test("Failed replacement restores the tree, all metadata and the index; successful replacement keeps saves")
    func replacement() async throws {
        let fm = FileManager.default
        let paths = AppPaths.temporary()
        defer {
            if let games = try? fm.contentsOfDirectory(at: paths.games(), includingPropertiesForKeys: nil) {
                for game in games {
                    try? OriginalGuard.unseal(originalRoot: game.appending(path: "Original"))
                }
            }
            try? fm.removeItem(at: paths.root.deletingLastPathComponent())
        }
        try paths.ensureLayout()
        let source = try source(at: paths.cachesRoot.appending(path: "source"))
        let store = try GameStore.open(paths: paths)
        let pipeline = ImportPipeline(paths: paths, store: store, session: SessionID(), registry: RuntimeRegistry())
        let id = try await pipeline.run(ImportTransaction(source: .folder(source), paths: paths))
        do {
            _ = try await pipeline.run(ImportTransaction(source: .folder(source), paths: paths))
            Issue.record("Expected duplicate detection")
        } catch let failure as ImportFailure {
            guard case .duplicate(existing: id, title: _) = failure else { throw failure }
        }
        let game = paths.game(id)
        let original = paths.tier(.original, for: id)
        let save = paths.tier(.saves, for: id).appending(path: "save.dat")
        try Data("keep my save".utf8).write(to: save)
        let sidecars = game.appending(path: "sidecars.json")
        try Data("old sidecars".utf8).write(to: sidecars)
        let metadata = [
            game.appending(path: "game.json"),
            game.appending(path: "original.manifest"),
            sidecars,
            paths.logs(game: id, session: UUID()).deletingLastPathComponent().appending(path: "detection.json"),
        ]
        let before = try metadata.map { try Data(contentsOf: $0) } // tiny synthetic metadata
        try fm.removeItem(at: source.appending(path: "old.txt"))
        try Data("new data".utf8).write(to: source.appending(path: "new.txt"))
        try failImports(store)
        let options = ImportPipeline.Options(duplicates: .replace(id))
        do {
            _ = try await pipeline.run(ImportTransaction(source: .folder(source), paths: paths), options: options)
            Issue.record("Expected replacement to fail")
        } catch {}
        #expect(try metadata.map { try Data(contentsOf: $0) } == before)
        #expect(fm.fileExists(atPath: original.appending(path: "old.txt").path(percentEncoded: false)))
        let index = try PathIndex.open(at: game.appending(path: "index.sqlite"))
        #expect(try index.lookup(layer: "original", key: "old.txt") != nil)
        #expect(try index.lookup(layer: "original", key: "new.txt") == nil)
        #expect(try store.imports.recent().count == 1)
        #expect(try store.fetchAll(DetectionResultRecord.self, game: id).count == 1)
        try await store.pool.write { try $0.execute(sql: "DROP TRIGGER fail_import") }
        let replaced = try await pipeline.run(ImportTransaction(source: .folder(source), paths: paths), options: options)
        #expect(replaced == id)
        #expect(try Data(contentsOf: save) == Data("keep my save".utf8))
        #expect(fm.fileExists(atPath: original.appending(path: "new.txt").path(percentEncoded: false)))
        #expect(!fm.fileExists(atPath: sidecars.path(percentEncoded: false)))
        #expect(try store.imports.recent().count == 2)
        #expect(!fm.fileExists(atPath: game.appending(path: "ImportRollback").path(percentEncoded: false)))

        try await verifyWebSaveAcknowledgement(paths: paths, id: id)
        try await verifyIncompleteSaveRefusal(paths: paths, id: id)
        try await verifyWebStorageQuotaRefusal(paths: paths, id: id)

        // Recovery promises to keep game files when recreating the database. Startup must also
        // preserve those unindexed trees on every later launch, including their irreplaceable saves.
        let model = await AppModel(paths: paths)
        await model.resetLibraryDatabase()
        #expect(await model.phase == .ready)
        #expect(try Data(contentsOf: save) == Data("keep my save".utf8))
        #expect(try Data(contentsOf: original.appending(path: "new.txt")) == Data("new data".utf8))
        let relaunched = await AppModel(paths: paths)
        await relaunched.launch()
        #expect(await relaunched.phase == .ready)
        #expect(try Data(contentsOf: save) == Data("keep my save".utf8))
        #expect(fm.fileExists(atPath: game.appending(path: "game.json").path(percentEncoded: false)))
    }

    /// Real WebKit → isolated bridge → atomic files, including an unwritable destination. The save
    /// boundary belongs in this existing data-integrity case, not a new mock runtime test.
    @MainActor private func verifyWebSaveAcknowledgement(paths: AppPaths, id: GameID) async throws {
        let model = AppModel(paths: paths)
        await model.launch()
        let record = try #require(try model.store?.games.fetch(id: id))
        let snapshot = try #require(AppModel.snapshot(for: id, paths: paths))
        let host = RuntimeHostViewController(sessionID: SessionID(), orientation: .any)
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 440, height: 956)
        host.view.layoutIfNeeded()
        _ = try await model.play(record, snapshot: snapshot, host: host)
        let web = try #require(host.containerView.subviews.compactMap { $0 as? WKWebView }.first)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if await (try? web.callAsyncJavaScript(
                "return typeof window.__omniplayFlushSaves === 'function'",
                in: nil,
                contentWorld: .page
            )) as? Bool == true {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        _ = try await web.callAsyncJavaScript("""
        localStorage.setItem('proof', 'first');
        localStorage.setItem('proof', 'durable');
        await window.__omniplayFlushSaves();
        """, in: nil, contentWorld: .page)
        let folder = paths.tier(.saves, for: id).appending(path: "persistent/webLocalStorage")
        let filename = SaveKey.encodeWebStorage("proof") + ".webstorage"
        #expect(try Data(contentsOf: folder.appending(path: filename)) == Data("durable".utf8))
        let held = folder.appendingPathExtension("held")
        try FileManager.default.moveItem(at: folder, to: held)
        try Data("block directory creation".utf8).write(to: folder)
        let rejected = try await web.callAsyncJavaScript("""
        localStorage.setItem('proof', 'must not be acknowledged');
        try { await window.__omniplayFlushSaves(); return false; } catch (_) { return true; }
        """, in: nil, contentWorld: .page)
        #expect(rejected as? Bool == true)
        #expect(model.saveWarning != nil)
        #expect(try Data(contentsOf: held.appending(path: filename)) == Data("durable".utf8))
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: held, to: folder)
        _ = try await web.callAsyncJavaScript("""
        localStorage.setItem('proof', 'after recovery');
        localStorage.setItem('__proto__', 'prototype key');
        await window.__omniplayFlushSaves();
        window.__oldPage = true;
        """, in: nil, contentWorld: .page)
        web.reload()
        let reloadDeadline = ContinuousClock.now + .seconds(10)
        var continued = false
        while ContinuousClock.now < reloadDeadline {
            continued = await (try? web.callAsyncJavaScript("""
            return !window.__oldPage && localStorage.getItem('proof') === 'after recovery' &&
                localStorage.getItem('__proto__') === 'prototype key';
            """, in: nil, contentWorld: .page)) as? Bool == true
            if continued {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(continued)
        await model.stopPlaying(reason: .hostShutdown)
        #expect(try Data(contentsOf: folder.appending(path: filename)) == Data("after recovery".utf8))
        #expect(await model.coordinator?.holdsRuntime == false)
    }

    @MainActor private func verifyIncompleteSaveRefusal(paths: AppPaths, id: GameID) async throws {
        let location = SaveLocation.forGame(id, paths: paths)
        let bridge = SaveBridge(location: location, engine: .html5)
        // A legitimate game key containing ".part-" must not be mistaken for an interrupted atomic write.
        let key = "rmmzsave.0.file1.part-legitimate"
        try await bridge.handle(op: "write", kind: "mz", key: key, value: Data("kept".utf8).base64EncodedString())
        let seeded = try await bridge.seed()
        #expect(seeded.contains(key))
        let folder = location.persistent.appending(path: "webLocalStorage")
        let invalid = folder.appending(path: SaveKey.encodeWebStorage("invalid") + ".webstorage")
        try Data([0xFF]).write(to: invalid)
        do {
            _ = try await bridge.seed()
            Issue.record("An invalid save must refuse launch, not disappear from the seed")
        } catch let error as SaveBridge.Failure {
            guard case .incompleteSeed = error else { throw error }
        }
        #expect(try Data(contentsOf: invalid) == Data([0xFF]))
        try FileManager.default.removeItem(at: invalid)
        let largeA = location.slots.appending(path: "rmmzsave.0.file1.rmmzsave")
        let largeB = location.slots.appending(path: "rmmzsave.0.file2.rmmzsave")
        let bytes = Data(repeating: 65, count: SaveFileStore.maxBytes)
        try bytes.write(to: largeA)
        try bytes.write(to: largeB)
        defer {
            try? FileManager.default.removeItem(at: largeA)
            try? FileManager.default.removeItem(at: largeB)
        }
        let model = AppModel(paths: paths)
        await model.launch()
        let record = try #require(try model.store?.games.fetch(id: id))
        let snapshot = try #require(AppModel.snapshot(for: id, paths: paths))
        let host = RuntimeHostViewController(sessionID: SessionID(), orientation: .any)
        host.loadViewIfNeeded()
        do {
            _ = try await model.play(record, snapshot: snapshot, host: host)
            await model.stopPlaying(reason: .hostShutdown)
            Issue.record("An incomplete seed must never reach a game page")
        } catch let error as CoordinatorError {
            guard case let .startFailed(detail) = error else { throw error }
            #expect(detail.contains("32 MB"))
        }
        #expect(host.containerView.subviews.compactMap { $0 as? WKWebView }.isEmpty)
        #expect(await model.coordinator?.holdsRuntime == false)
        #expect(try Data(contentsOf: largeA) == bytes)
        #expect(try Data(contentsOf: largeB) == bytes)
    }

    @MainActor private func verifyWebStorageQuotaRefusal(paths: AppPaths, id: GameID) async throws {
        let folder = SaveLocation.forGame(id, paths: paths).persistent.appending(path: "webLocalStorage")
        let file = folder.appending(path: SaveKey.encodeWebStorage("large") + ".webstorage")
        let bytes = Data(repeating: 65, count: SaveFileStore.maxBytes)
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let model = AppModel(paths: paths)
        await model.launch()
        let record = try #require(try model.store?.games.fetch(id: id))
        let snapshot = try #require(AppModel.snapshot(for: id, paths: paths))
        let host = RuntimeHostViewController(sessionID: SessionID(), orientation: .any)
        host.loadViewIfNeeded()
        _ = try await model.play(record, snapshot: snapshot, host: host)
        let web = try #require(host.containerView.subviews.compactMap { $0 as? WKWebView }.first)
        let deadline = ContinuousClock.now + .seconds(10)
        while model.runtimeFailure == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(model.runtimeFailure?.contains("saves could not all be loaded") == true)
        let blocked = try await web.callAsyncJavaScript("""
        try { localStorage.setItem('large', 'overwrite'); return false; } catch (_) { return true; }
        """, in: nil, contentWorld: .page)
        #expect(blocked as? Bool == true)
        await model.stopPlaying(reason: .hostShutdown)
        #expect(try Data(contentsOf: file) == bytes)
    }

    private func source(at root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><html><body>Game</body></html>".utf8).write(to: root.appending(path: "index.html"))
        try Data("old data".utf8).write(to: root.appending(path: "old.txt"))
        return root
    }

    private func failImports(_ store: GameStore) throws {
        try store.pool.write {
            try $0
                .execute(
                    sql: "CREATE TRIGGER fail_import BEFORE INSERT ON import_records BEGIN SELECT RAISE(ABORT, 'injected failure'); END"
                )
        }
    }
}
