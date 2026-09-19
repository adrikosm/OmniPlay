import Foundation
import GameCore
import GameImport
import GameStore
import Observation

/// One row on the Import screen: a transaction and its latest state.
@Observable @MainActor
final class ImportItem: Identifiable {
    let id: UUID
    let name: String
    let transaction: ImportTransaction
    private(set) var state: ImportState = .queued
    private var watcher: Task<Void, Never>?

    init(transaction: ImportTransaction, name: String) {
        id = transaction.id
        self.transaction = transaction
        self.name = name
        watcher = Task { [weak self] in
            for await state in await transaction.states {
                guard let self else { return }
                self.state = state
            }
        }
    }

    func cancel() { Task { await transaction.cancel() } }
}

/// Queues imports from the Files picker and keeps the rows the screen shows.
@Observable @MainActor
final class ImportsModel {
    private(set) var items: [ImportItem] = []
    private let coordinator: ImportCoordinator
    private let pipeline: ImportPipeline

    init(coordinator: ImportCoordinator, pipeline: ImportPipeline) {
        self.coordinator = coordinator
        self.pipeline = pipeline
    }

    func enqueue(_ url: URL) async {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let source: ImportSource = isDirectory ? .folder(url) : .file(url)
        let pipeline = pipeline
        let txn = await coordinator.enqueue(source: source) { try await pipeline.run($0) }
        items.insert(ImportItem(transaction: txn, name: url.lastPathComponent), at: 0)
    }

    func clearFinished() { items.removeAll { $0.state.isTerminal } }
}
