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
    var query = "" { didSet {
        if query != oldValue {
            runSearch()
        }
    } }
    var sort: LibrarySort = .recentlyPlayed { didSet { restart() } }
    var filter: LibraryFilter = .all { didSet { restart() } }
    var error: String?
    /// All, Favourites and Hidden counts for the filter bar.
    var counts: [LibraryFilter: Int] = [:]
    /// The player's collections, for the filter bar and the cover menu (UI-007).
    var collections: [CollectionSummary] = []
    private let store: GameStore
    private let paths: AppPaths
    private var observation: Task<Void, Never>?
    private var countObservation: Task<Void, Never>?
    private var collectionObservation: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    init(store: GameStore, paths: AppPaths) {
        self.store = store
        self.paths = paths
        restart()
        let counts = store.observeCounts()
        countObservation = Task { [weak self] in
            // A failed count only leaves the numbers off the filter bar; the shelf reports its own errors.
            do {
                for try await value in counts {
                    self?.counts = value
                }
            } catch {}
        }
        let collections = store.observeCollections()
        collectionObservation = Task { [weak self] in
            do {
                for try await value in collections {
                    self?.collections = value
                }
            } catch {}
        }
    }

    isolated deinit {
        observation?.cancel()
        countObservation?.cancel()
        collectionObservation?.cancel()
        searchTask?.cancel()
    }

    // MARK: Collections

    func memberships(of game: GameRecord) -> Set<String> { (try? store.collections.memberships(of: game.id)) ?? [] }

    func setMember(_ game: GameRecord, of collection: String, _ on: Bool) {
        try? store.collections.set(game.id, in: collection, member: on)
    }

    /// A new collection, with `game` in it when one is given. Names are unique regardless of case.
    func createCollection(named raw: String, with game: GameRecord?) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let existing = collections.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            if let game {
                setMember(game, of: existing.id, true)
            }
            return
        }
        do {
            let id = try store.collections.create(name: name)
            if let game {
                setMember(game, of: id, true)
            }
        } catch {
            self.error = "The collection could not be made: \(error.localizedDescription)"
        }
    }

    func deleteCollection(_ id: String) {
        try? store.collections.delete(id: id)
        if filter == .collection(id) {
            filter = .all
        }
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
                        runSearch()
                    }
                }
            } catch {
                self?.error = "Library updates stopped: \(error.localizedDescription)"
                OPLog.log(.ui, .error, "library observation failed: \(error)")
            }
        }
    }

    private func runSearch() {
        searchTask?.cancel()
        // Cleared: re-observing emits the current filtered, sorted list straight away.
        guard !query.isEmpty else { restart(); return }
        let store = store
        let query = query
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            let result = await Task.detached { try? store.games.search(query) }.value
            guard !Task.isCancelled, let self, self.query == query, let result else { return }
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
