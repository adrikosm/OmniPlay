import Diagnostics
import Foundation
import GameCore

public struct ImportProgress: Sendable, Hashable {
    public var completedBytes: Int64
    public var totalBytes: Int64?
    public var currentItem: String?

    public init(completedBytes: Int64 = 0, totalBytes: Int64? = nil, currentItem: String? = nil) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.currentItem = currentItem
    }
}

/// One explicit state machine; every state maps to UI progress and a diagnostics line.
public enum ImportState: Sendable, Hashable {
    case queued
    case staging(ImportProgress)
    case inspecting
    case extracting(ImportProgress)
    case normalizing
    case detecting
    case resolvingRuntime
    case analyzingMedia
    case preparing(ImportProgress)
    case registering
    case ready(GameID)
    case failed(ImportFailure)
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .ready, .failed, .cancelled: true
        default: false
        }
    }

    var label: String {
        switch self {
        case .queued: "queued"
        case .staging: "staging"
        case .inspecting: "inspecting"
        case .extracting: "extracting"
        case .normalizing: "normalizing"
        case .detecting: "detecting"
        case .resolvingRuntime: "resolvingRuntime"
        case .analyzingMedia: "analyzingMedia"
        case .preparing: "preparing"
        case .registering: "registering"
        case .ready: "ready"
        case .failed: "failed"
        case .cancelled: "cancelled"
        }
    }
}

public enum ImportFailure: Error, Sendable, Hashable {
    case unreadableSource(String)
    case unsupportedContainer(firstBytesHex: String)
    case safetyViolation(SafetyViolation)
    case storageInsufficient(required: Int64, available: Int64)
    case extractionFailed(entry: String, underlying: String)
    case passwordRequired
    case noGameRoot
    /// Several plausible game folders; the user picks one (relative paths inside the staged tree).
    case multipleRoots([String])
    /// The same source was imported before; the user chooses replace / keep both / cancel.
    case duplicate(existing: GameID, title: String)
    case detectionRefused(reason: String)
    case cancelled
    case internalError(String)
}

public enum ImportSource: Sendable, Hashable {
    case file(URL)
    case folder(URL)

    public var url: URL {
        switch self {
        case let .file(u), let .folder(u): u
        }
    }
}

/// One import from source to registered game. Owns a staging directory that `rollback()` deletes entirely.
/// States are published as an `AsyncStream`; cancel the transaction (not the Task) to get `.cancelled`.
public actor ImportTransaction {
    public nonisolated let id: UUID
    public nonisolated let source: ImportSource
    public nonisolated let stagingURL: URL
    public private(set) var state: ImportState = .queued
    private var signpost = SignpostPhase(Signposts.importer)
    private var continuations: [UUID: AsyncStream<ImportState>.Continuation] = [:]
    private var history: [ImportState] = [.queued]
    private var work: Task<Void, Never>?

    public init(id: UUID = UUID(), source: ImportSource, paths: AppPaths) {
        self.id = id
        self.source = source
        stagingURL = paths.importStaging(txn: id)
    }

    public var states: AsyncStream<ImportState> {
        AsyncStream { continuation in
            let key = UUID()
            continuation.yield(state)
            if state.isTerminal {
                continuation.finish(); return
            }
            continuations[key] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.dropContinuation(key) } }
        }
    }

    /// Every state visited so far, in order (for tests and diagnostics).
    public var visited: [ImportState] { history }

    public func transition(to next: ImportState) {
        guard !state.isTerminal else { return }
        state = next
        history.append(next)
        if next.isTerminal {
            signpost.end()
        } else {
            signpost.enter("import phase", next.label)
        }
        OPLog.log(.importer, .info, "txn \(id) → \(next.label)")
        for c in continuations.values {
            c.yield(next)
        }
        if next.isTerminal {
            for c in continuations.values {
                c.finish()
            }
            continuations.removeAll()
        }
    }

    /// Runs `body` as the transaction's work. A thrown `ImportFailure` (or any error) rolls back and ends in `.failed`;
    /// cancellation rolls back and ends in `.cancelled`.
    public func run(_ body: @escaping @Sendable (ImportTransaction) async throws -> GameID) {
        guard work == nil else { return }
        work = Task { [self] in
            do {
                try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
                let game = try await body(self)
                try? FileManager.default.removeItem(at: stagingURL) // commit moved what it needed; nothing stays in staging
                await transition(to: .ready(game))
            } catch is CancellationError {
                await rollback()
                await transition(to: .cancelled)
            } catch let failure as ImportFailure {
                await rollback()
                await transition(to: .failed(failure))
            } catch let storage as StorageError {
                await rollback()
                if case let .insufficientSpace(required, available, _) = storage {
                    await transition(to: .failed(.storageInsufficient(required: required, available: available)))
                }
            } catch {
                await rollback()
                await transition(to: .failed(.internalError(String(describing: error))))
            }
        }
    }

    /// Waits for the work to end.
    public func wait() async { await work?.value }

    public func cancel() {
        work?.cancel()
        if work == nil {
            transition(to: .cancelled)
        }
    }

    /// Deletes the staging directory. Safe to call more than once.
    public func rollback() {
        try? FileManager.default.removeItem(at: stagingURL)
        OPLog.log(.importer, .info, "txn \(id) rolled back")
    }

    private func dropContinuation(_ key: UUID) { continuations[key] = nil }
}

/// Runs one transaction at a time.
public actor ImportCoordinator {
    public let paths: AppPaths
    private var queue: [(ImportTransaction, @Sendable (ImportTransaction) async throws -> GameID)] = []
    private var running = false

    public init(paths: AppPaths) { self.paths = paths }

    @discardableResult
    public func enqueue(source: ImportSource, body: @escaping @Sendable (ImportTransaction) async throws -> GameID) -> ImportTransaction {
        let txn = ImportTransaction(source: source, paths: paths)
        queue.append((txn, body))
        Task { await pump() }
        return txn
    }

    private func pump() async {
        guard !running, !queue.isEmpty else { return }
        running = true
        let (txn, body) = queue.removeFirst()
        await txn.run(body)
        await txn.wait()
        running = false
        await pump()
    }

    /// Removes staging directories older than `age` (24 h by default): leftovers of a crashed process.
    @discardableResult
    public static func sweepStaleStaging(paths: AppPaths, olderThan age: TimeInterval = 24 * 3600, now: Date = .now) -> Int {
        let root = paths.importStaging(txn: UUID()).deletingLastPathComponent()
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return 0 }
        var removed = 0
        for dir in dirs {
            let modified = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(modified) > age, (try? FileManager.default.removeItem(at: dir)) != nil {
                removed += 1
            }
        }
        if removed > 0 {
            OPLog.log(.importer, .info, "swept \(removed) stale staging directories")
        }
        return removed
    }
}
