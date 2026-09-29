import Foundation
import GameCore
import GameStore
import OverlayVFS
import SaveKit

/// Deleting a game, from its cover's menu or the foot of its page: the saves are rescued first, the library row goes
/// next, the files last. Runs off the main actor; returns what went wrong, or nil.
enum GameDeletion {
    nonisolated static func run(_ game: GameRecord, store: GameStore, paths: AppPaths) -> String? {
        do {
            let titleHash = AppModel.snapshot(for: game.id, paths: paths)?.report.descriptor.identityHash ?? game.id.description
            let location = SaveLocation.forGame(game.id, paths: paths)
            let rescued = try RescuedSaves.rescue(location: location, titleHash: titleHash, title: game.title, paths: paths)
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
            try? FileManager.default.removeItem(at: paths.game(game.id))
            try? FileManager.default.removeItem(at: paths.tier(.runtimeCache, for: game.id))
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
