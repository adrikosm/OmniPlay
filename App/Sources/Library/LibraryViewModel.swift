import Diagnostics
import Foundation
import GameCore
import GameStore
import Observation
import OverlayVFS
import SaveKit

/// Drives the Library screen from the store's observation stream; search goes through FTS.
@Observable @MainActor
final class LibraryViewModel {
    var games: [GameRecord] = []
    var query = "" { didSet { Task { await runSearch() } } }
    var sort: LibrarySort = .recentlyImported { didSet { restart() } }
    var filter: LibraryFilter = .all { didSet { restart() } }
    var error: String?
    private let store: GameStore
    private let paths: AppPaths
    private var observation: Task<Void, Never>?

    init(store: GameStore, paths: AppPaths) {
        self.store = store
        self.paths = paths
        restart()
    }

    private func restart() {
        observation?.cancel()
        let stream = store.observeLibrary(sort: sort, filter: filter)
        observation = Task { [weak self] in
            do {
                for try await list in stream {
                    guard let self, !Task.isCancelled else { return }
                    if query.isEmpty {
                        games = list
                    } else {
                        await runSearch()
                    }
                }
            } catch {
                self?.error = "Library updates stopped: \(error.localizedDescription)"
                OPLog.log(.ui, .error, "library observation failed: \(error)")
            }
        }
    }

    private func runSearch() async {
        guard !query.isEmpty else { return }
        let store = store
        let query = query
        let result = await Task.detached { try? store.games.search(query) }.value
        if self.query == query, let result {
            games = result
        }
    }

    func setFavorite(_ game: GameRecord, _ on: Bool) {
        var updated = game
        updated.favorite = on
        try? store.games.update(updated)
    }

    func setHidden(_ game: GameRecord, _ on: Bool) {
        var updated = game
        updated.hidden = on
        try? store.games.update(updated)
    }

    /// Removes the library entry and the game tree. Saves are moved to the user-visible export folder first.
    func delete(_ game: GameRecord) async {
        let store = store
        let paths = paths
        let outcome = await Task.detached { () -> String? in
            do {
                let titleHash = AppModel.snapshot(for: game.id, paths: paths)?.report.descriptor.identityHash ?? game.id.description
                try RescuedSaves.rescue(
                    location: SaveLocation.forGame(game.id, paths: paths),
                    titleHash: titleHash,
                    title: game.title,
                    paths: paths
                )
                try? OriginalGuard.unseal(originalRoot: paths.tier(.original, for: game.id))
                try? FileManager.default.removeItem(at: paths.game(game.id))
                try? FileManager.default.removeItem(at: paths.tier(.runtimeCache, for: game.id))
                try store.games.delete(id: game.id)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let outcome {
            error = outcome
        }
    }
}
