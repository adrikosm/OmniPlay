import Diagnostics
import Foundation
import GameCore
import GameDetection
import GameStore
import SaveKit

extension AppModel {
    /// Rebuilds `saves_meta` from the slot files so the library can show what a game has saved.
    func indexSaves(for descriptor: GameDescriptor) {
        guard let store else { return }
        let location = SaveLocation.forGame(descriptor.id, paths: paths)
        // Slot files only: Ren'Py's `persistent` and `sync/`, and MV/MZ's save list and config, are not saves.
        let records = SaveSlotFile.list(in: location.slots).map { slot in
            let stem = slot.url.deletingPathExtension().lastPathComponent
            return SaveMetaRecord(
                gameId: descriptor.id,
                slotKey: SaveKey.decodeWebStorage(stem) ?? stem,
                relPath: "Saves/slots/\(slot.id)",
                family: descriptor.saveFamily.rawValue,
                bytes: slot.bytes,
                modifiedAt: slot.modified ?? .now,
                provenanceHash: descriptor.identityHash
            )
        }
        try? store.saves.replaceAll(game: descriptor.id, with: records)
        let kinds = SaveStrategy.forEngine(descriptor.engine, generation: descriptor.generation).persistentStores
            .compactMap { PersistentStoreKind(rawValue: $0.rawValue) }
        let stores = PersistentStoreRegistry.stores(location: location, kinds: kinds).filter(\.isPresent).map {
            PersistentStoreRecord(
                gameId: descriptor.id,
                kind: $0.kind.rawValue,
                relPath: paths.stored($0.directory),
                bytes: $0.bytes,
                modifiedAt: $0.modifiedAt ?? .now
            )
        }
        try? store.persistentStores.replaceAll(game: descriptor.id, with: stores)
        let title = (try? store.games.fetch(id: descriptor.id))?.title ?? descriptor.title
        Task { await mirrorSaves(descriptor.id, title: title) }
    }

    // MARK: Saves in the Files app

    var saveMirror: SaveMirror { SaveMirror(root: paths.savesMirror) }

    /// Rewrites `Titles/Saves/<Title>/` from the real saves. Unless `force`, a folder with unanswered changes is kept.
    func mirrorSaves(_ id: GameID, title: String, force: Bool = false) async {
        let (mirror, location) = (saveMirror, SaveLocation.forGame(id, paths: paths))
        do {
            try await Task.detached(priority: .utility) { _ = try mirror.write(from: location, id: id, title: title, force: force) }.value
        } catch {
            OPLog.log(.save, .error, "save mirror of \(title) not written: \(error.localizedDescription)")
        }
    }

    /// Files added or changed in the game's Files folder since OmniPlay last wrote it.
    func mirrorChanges(for game: GameRecord) -> [String] { saveMirror.pendingChanges(for: game.id, title: game.title) }

    /// Imports the changed files through the normal save import (validation, snapshot, transaction), replacing
    /// same-named slots; once installed, the folder is rewritten from the real saves.
    func useMirrorChanges(for game: GameRecord, confirmed: Bool) async throws -> SaveTransfer.Outcome {
        let staging = paths.tier(.importStaging, for: game.id).appending(path: "mirror-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        _ = try saveMirror.stageChanges(for: game.id, title: game.title, into: staging)
        let outcome = try await SaveTransfer(paths: paths, game: game).importSaves(from: staging, collision: .replace, confirmed: confirmed)
        if case .installed = outcome {
            reindexSaves(game.id)
            await mirrorSaves(game.id, title: game.title, force: true)
        }
        return outcome
    }
}
