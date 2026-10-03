import Foundation
import GameCore
import GameStore
import OverlayVFS
import RuntimeCore
import SaveKit

/// Deleting a game, from its cover's menu or the foot of its page. Keeping saves rescues them first; either way the
/// library row goes next, the files last. Returns what went wrong, or nil.
enum GameDeletion {
    static let explanation = "Keeping saves brings them back if you import the same game again. "
        + "Deleting all its data also removes its saves, settings and logs, and cannot be undone."

    @MainActor
    static func run(_ game: GameRecord, keepSaves: Bool, store: GameStore, paths: AppPaths) async -> String? {
        let failure = await Task.detached { files(game, keepSaves: keepSaves, store: store, paths: paths) }.value
        // A re-import gets a new id, so the game's WebKit storage would never be read again.
        if failure == nil {
            await WebRuntime.removeData(for: game.id)
        }
        return failure
    }

    private nonisolated static func files(_ game: GameRecord, keepSaves: Bool, store: GameStore, paths: AppPaths) -> String? {
        guard ImportPipeline.claim(game.id) else { return "An import is replacing this game. Delete it once the import finishes." }
        defer { ImportPipeline.release(game.id) }
        do {
            let titleHash = AppModel.identityHash(for: game.id, paths: paths)
            let location = SaveLocation.forGame(game.id, paths: paths)
            let rescued = keepSaves
                ? try RescuedSaves.rescue(location: location, titleHash: titleHash, title: game.title, paths: paths)
                : nil
            // The row goes before the files: if the database refuses, the game stays whole, listed and with its
            // saves put back. The other order could leave a library entry whose files are already gone.
            do {
                try store.games.delete(id: game.id)
            } catch {
                if let rescued {
                    try? RescuedSaves.restore(from: rescued, into: location)
                }
                throw error
            }
            try? OriginalGuard.unseal(originalRoot: paths.tier(.original, for: game.id))
            // A replacement's backup keeps the old tree sealed too; a plain remove would leave it behind.
            for backup in ["ImportRollback", ImportPipeline.committedRollback] {
                ImportPipeline.removeSealed(paths.game(game.id).appending(path: backup, directoryHint: .isDirectory))
            }
            try? FileManager.default.removeItem(at: paths.game(game.id))
            try? FileManager.default.removeItem(at: paths.tier(.runtimeCache, for: game.id))
            if !keepSaves {
                for old in RescuedSaves.find(titleHash: titleHash, paths: paths) {
                    try? FileManager.default.removeItem(at: old.directory)
                }
                try? FileManager.default.removeItem(at: paths.logsRoot().appending(path: game.id.description, directoryHint: .isDirectory))
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
