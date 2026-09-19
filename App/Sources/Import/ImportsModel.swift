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
    /// Answers already given for this source; a retry adds one more.
    let options: ImportPipeline.Options
    private(set) var state: ImportState = .queued
    private var watcher: Task<Void, Never>?

    init(transaction: ImportTransaction, name: String, options: ImportPipeline.Options = .init()) {
        id = transaction.id
        self.transaction = transaction
        self.name = name
        self.options = options
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

    func enqueue(_ url: URL, options: ImportPipeline.Options = .init()) async {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let source: ImportSource = isDirectory ? .folder(url) : .file(url)
        let pipeline = pipeline
        let txn = await coordinator.enqueue(source: source) { try await pipeline.run($0, options: options) }
        items.insert(ImportItem(transaction: txn, name: url.lastPathComponent, options: options), at: 0)
    }

    /// Re-runs an import with one more answer (duplicate choice, passphrase, chosen root) and drops the row that asked.
    func resolve(_ item: ImportItem, _ change: (inout ImportPipeline.Options) -> Void) async {
        var options = item.options
        change(&options)
        items.removeAll { $0.id == item.id }
        await enqueue(item.transaction.source.url, options: options)
    }

    func clearFinished() { items.removeAll { $0.state.isTerminal } }
}
