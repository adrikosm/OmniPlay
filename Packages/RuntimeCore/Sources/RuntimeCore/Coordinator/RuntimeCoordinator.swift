import Diagnostics
import Foundation
import GameCore
import GameStore
import InputKit

/// What the app hands the coordinator: the record, the descriptor and the resolution already made for this game.
public struct LaunchRequest: Sendable {
    public let record: GameRecord
    public let descriptor: GameDescriptor
    public let resolution: RuntimeResolution
    public let configuration: RuntimeConfiguration

    public init(record: GameRecord, descriptor: GameDescriptor, resolution: RuntimeResolution, configuration: RuntimeConfiguration) {
        self.record = record
        self.descriptor = descriptor
        self.resolution = resolution
        self.configuration = configuration
    }
}

public struct ActiveSession: Sendable, Hashable {
    public let id: UUID
    public let gameID: GameID
    public let runtime: RuntimeIdentifier
    public let slot: SessionSlot
    public let startedAt: Date
}

public enum LaunchPreflight: Sendable, Equatable {
    case ok
    case slotBusy(activeGame: GameID)
    case slotSpent(SessionSlotLedger.SlotSpentReason)
    case notBuilt(RuntimeIdentifier)
    case noRuntime(String)
}

public enum CoordinatorError: Error, Sendable, Equatable {
    case busy
    case preflight(LaunchPreflight)
    case prepareFailed(String)
    case startFailed(String)
}

/// Builds an adapter for a runtime identifier. Registered by each adapter module; the coordinator never imports one.
public typealias RuntimeFactory = @MainActor @Sendable (RuntimeConfiguration) -> any GameRuntime

/// The only thing that may start or stop a session: one non-idle runtime at a time, no launch while
/// stopping, teardown completes before idle, verdicts recorded in the ledger and the session table.
public actor RuntimeCoordinator {
    public enum State: Sendable, Equatable {
        case idle
        case preparing(GameID)
        case launching(GameID)
        case running(ActiveSession)
        case paused(ActiveSession)
        case stopping(ActiveSession)
        case failed(String)
        case stopped(TeardownVerdict)

        public var isIdle: Bool {
            if case .idle = self {
                true
            } else if case .stopped = self {
                true
            } else if case .failed = self {
                true
            } else {
                false
            }
        }
    }

    public static let stopTimeout: Duration = .seconds(10)

    public private(set) var state: State = .idle
    public let ledger = SessionSlotLedger()
    public private(set) var restartRequired = false
    private let store: GameStore?
    private var factories: [RuntimeIdentifier: RuntimeFactory] = [:]
    private var runtime: (any GameRuntime)?
    private var stateContinuations: [UUID: AsyncStream<State>.Continuation] = [:]

    /// One id per process launch; ledger rows from other boots are stale and ignored.
    public let bootID: String
    private var restoredSpent = false

    public init(store: GameStore?, bootID: String = UUID().uuidString) {
        self.store = store
        self.bootID = bootID
    }

    /// Spent slots persisted by this boot come back into the in-memory ledger once.
    private func restoreSpentIfNeeded() async {
        guard !restoredSpent else { return }
        restoredSpent = true
        for slot in (try? store?.slots.spent(bootID: bootID)) ?? [] {
            await ledger.markSpent(slot)
        }
    }

    /// Slots that need an app relaunch before any game can use them again.
    public func spentSlots() async -> Set<SessionSlot> {
        await restoreSpentIfNeeded()
        return await ledger.spentSlots
    }

    public func register(_ id: RuntimeIdentifier, factory: @escaping RuntimeFactory) { factories[id] = factory }
    public var registeredRuntimes: [RuntimeIdentifier] { Array(factories.keys) }

    public var states: AsyncStream<State> {
        AsyncStream { continuation in
            let key = UUID()
            continuation.yield(state)
            stateContinuations[key] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.dropContinuation(key) } }
        }
    }

    private func dropContinuation(_ key: UUID) { stateContinuations[key] = nil }

    private func set(_ new: State) {
        state = new
        OPLog.log(.runtime, .info, "coordinator → \(new)")
        for c in stateContinuations.values {
            c.yield(new)
        }
    }

    /// Can this game launch right now, before any adapter is built?
    public func preflight(_ request: LaunchRequest) async -> LaunchPreflight {
        await restoreSpentIfNeeded()
        guard let runtimeID = request.resolution.selectedRuntime else { return .noRuntime(request.resolution.reason) }
        guard factories[runtimeID] != nil else { return .notBuilt(runtimeID) }
        switch await ledger.launchVerdict(for: runtimeID.slot, game: request.record.id.rawValue) {
        case .ready: return .ok
        case let .slotBusy(active): return .slotBusy(activeGame: GameID(active))
        case let .restartRequired(reason): return .slotSpent(reason)
        }
    }

    /// Prepares, starts and records a session. Throws with the state left in `.failed`.
    @discardableResult
    public func launch(_ request: LaunchRequest, host: any RuntimeHost) async throws -> ActiveSession {
        guard state.isIdle else { throw CoordinatorError.busy }
        let pre = await preflight(request)
        guard pre == .ok, let runtimeID = request.resolution.selectedRuntime, let factory = factories[runtimeID] else {
            set(.failed("preflight: \(pre)"))
            throw CoordinatorError.preflight(pre)
        }
        let gameID = request.record.id
        set(.preparing(gameID))
        let adapter = await factory(request.configuration)
        runtime = adapter
        do {
            try await adapter.prepare(configuration: request.configuration)
        } catch {
            runtime = nil
            set(.failed("prepare: \(error)"))
            throw CoordinatorError.prepareFailed(String(describing: error))
        }
        set(.launching(gameID))
        let session = ActiveSession(
            id: request.configuration.sessionID.rawValue,
            gameID: gameID,
            runtime: runtimeID,
            slot: runtimeID.slot,
            startedAt: .now
        )
        try? await ledger.recordStart(of: session.slot, game: gameID.rawValue)
        do {
            try await adapter.start(in: host)
        } catch {
            await ledger.recordStop(of: session.slot, game: gameID.rawValue, verdict: .clean)
            runtime = nil
            set(.failed("start: \(error)"))
            throw CoordinatorError.startFailed(String(describing: error))
        }
        try? store?.sessions.begin(SessionRecord(id: session.id, gameId: gameID, runtime: runtimeID))
        set(.running(session))
        return session
    }

    public func pause() async {
        guard case let .running(session) = state, let runtime else { return }
        await runtime.pause()
        set(.paused(session))
    }

    public func resume() async {
        guard case let .paused(session) = state, let runtime else { return }
        await runtime.resume()
        set(.running(session))
    }

    /// Stops the active runtime, waits for the verdict (10 s cap), records it and releases the adapter.
    @discardableResult
    public func stop(reason: RuntimeStopReason, grade: PlayabilityGrade? = nil, peakFootprint: Int64? = nil) async -> TeardownVerdict {
        let session: ActiveSession
        switch state {
        case let .running(s), let .paused(s): session = s
        default: return .clean
        }
        guard let runtime else { set(.idle); return .clean }
        set(.stopping(session))
        let verdict: TeardownVerdict = await withTaskGroup(of: TeardownVerdict.self) { group in
            group.addTask { await runtime.stop(reason: reason) }
            group.addTask {
                try? await Task.sleep(for: RuntimeCoordinator.stopTimeout)
                OPLog.log(.runtime, .error, "runtime stop timed out; releasing anyway")
                return .restartRequired
            }
            let first = await group.next() ?? .clean
            group.cancelAll()
            return first
        }
        self.runtime = nil
        await ledger.recordStop(of: session.slot, game: session.gameID.rawValue, verdict: verdict)
        if verdict == .restartRequired {
            restartRequired = true
        }
        if verdict != .clean {
            try? store?.slots.markSpent(bootID: bootID, slot: session.slot, by: session.gameID)
        }
        try? store?.sessions.end(id: session.id, verdict: "\(verdict)", grade: grade, peakFootprint: peakFootprint, notes: "\(reason)")
        set(.stopped(verdict))
        set(.idle)
        return verdict
    }

    /// Reports a runtime-side failure (crash, hang) and tears down.
    public func fail(_ detail: String) async {
        _ = await stop(reason: .crash(detail: detail))
        set(.failed(detail))
    }

    public func send(_ event: GameInputEvent) async { await runtime?.send(event) }
    public func forward(memoryPressure level: MemoryPressureLevel) async { await runtime?.handleMemoryPressure(level) }
    public func forward(thermal state: ProcessInfo.ThermalState) async { await runtime?.handleThermalState(state) }

    /// The session in `.running` or `.paused`, if any.
    public var activeSession: ActiveSession? {
        switch state {
        case let .running(s), let .paused(s): s
        default: nil
        }
    }

    /// True while an adapter object is retained (tests assert release after stop).
    public var holdsRuntime: Bool { runtime != nil }
}
