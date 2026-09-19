import Diagnostics
import Foundation
import GameCore
import GameStore
import Observation
import OverlayVFS

/// Drives the Library screen from the store's observation stream; search goes through FTS.
@Observable @MainActor
final class LibraryViewModel {
    var games: [GameRecord] = []
    var query = "" { didSet { Task { await runSearch() } } }
    var sort: LibrarySort = .recentlyImported { didSet { restart() } }
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
        let stream = store.observeLibrary(sort: sort)
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

    /// Removes the library entry and the game tree. Saves are moved to the user-visible export folder first.
    func delete(_ game: GameRecord) async {
        let store = store
        let paths = paths
        let outcome = await Task.detached { () -> String? in
            do {
                let saves = paths.tier(.saves, for: game.id)
                if FileManager.default.fileExists(atPath: saves.path(percentEncoded: false)) {
                    let rescued = paths.exportsRoot.appending(
                        path: "Rescued Saves/\(game.title) \(game.id.description.prefix(8))",
                        directoryHint: .isDirectory
                    )
                    try FileManager.default.createDirectory(at: rescued.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: saves, to: rescued)
                }
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
