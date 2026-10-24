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
    @ObservationIgnored private let answers: ImportAnswers

    init(
        transaction: ImportTransaction,
        name: String,
        options: ImportPipeline.Options = .init(),
        answers: ImportAnswers = ImportAnswers(),
        onReady: (@MainActor (GameID) -> Void)? = nil
    ) {
        id = transaction.id
        self.transaction = transaction
        self.name = name
        self.options = options
        self.answers = answers
        watcher = Task { [weak self] in
            for await state in await transaction.states {
                guard let self else { return }
                self.state = state
                if case let .ready(id) = state {
                    onReady?(id)
                }
            }
        }
    }

    func cancel() { Task { await transaction.cancel() } }

    /// Answers the question the import is waiting on.
    func answer(_ answer: ImportAnswer) { answers.answer(answer) }
}

/// Where an import's question waits for the row's answer. Cancelling the import answers Cancel.
@MainActor
final class ImportAnswers {
    private var pending: CheckedContinuation<ImportAnswer, Never>?
    /// Cancel can arrive before the question is waiting.
    private var cancelled = false

    func ask() async -> ImportAnswer {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if cancelled {
                    continuation.resume(returning: .cancel)
                } else {
                    pending = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.answer(.cancel) }
        }
    }

    func answer(_ answer: ImportAnswer) {
        guard let pending else {
            cancelled = cancelled || answer == .cancel
            return
        }
        self.pending = nil
        pending.resume(returning: answer)
    }
}

/// Queues imports from the Files picker and keeps the rows the screen shows.
@Observable @MainActor
final class ImportsModel {
    private(set) var items: [ImportItem] = []
    /// Each game an import registers, once.
    var onImported: (@MainActor (GameID) -> Void)?
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
        let answers = ImportAnswers()
        var asking = options
        asking.ask = { _ in await answers.ask() }
        let txn = await coordinator.enqueue(source: source) { [asking] in
            let id = try await pipeline.run($0, options: asking)
            pipeline.completeHashingLater(id)
            // A Wi-Fi upload lands in our own staging; imported, it is only a second copy of the game.
            let staging = pipeline.paths.tier(.importStaging, for: id).standardizedFileURL.path(percentEncoded: false)
            if url.standardizedFileURL.path(percentEncoded: false).hasPrefix(staging) {
                try? FileManager.default.removeItem(at: url)
            }
            return id
        }
        items.insert(
            ImportItem(transaction: txn, name: url.lastPathComponent, options: options, answers: answers) { [weak self] in
                self?.onImported?($0)
            },
            at: 0
        )
    }

    /// Re-runs an import with a passphrase and drops the row that asked.
    func resolve(_ item: ImportItem, _ change: (inout ImportPipeline.Options) -> Void) async {
        var options = item.options
        change(&options)
        items.removeAll { $0.id == item.id }
        await enqueue(item.transaction.source.url, options: options)
    }

    func clearFinished() { items.removeAll { $0.state.isTerminal } }
}
