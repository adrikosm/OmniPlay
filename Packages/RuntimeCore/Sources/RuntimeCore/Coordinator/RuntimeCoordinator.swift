import CoreGraphics
import Diagnostics
import Foundation
import GameCore
import GameStore
import InputKit

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
    private var launchTask: Task<ActiveSession, Error>?
    private var stopTask: Task<TeardownVerdict, Never>?
    private var lastVerdict: TeardownVerdict = .clean
    private var lifecycleRevision = UUID()
    /// Present from launch until teardown ran; a leftover at the next launch means the session never got one.
    private var marker: SessionMarker?
    private var stateContinuations: [UUID: AsyncStream<State>.Continuation] = [:]

    /// One id per process launch; ledger rows from other boots are stale and ignored.
    public let bootID: String
    private var signpost = SignpostPhase(Signposts.runtime)
    private var memory: MemoryRecorder?
    private var memoryTask: Task<Void, Never>?
    private var peakFootprint: UInt64 = 0
    private var restoredSpent = false
    private var systemWatch: Task<Void, Never>?

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

    public var states: AsyncStream<State> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let key = UUID()
            continuation.yield(state)
            stateContinuations[key] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.dropContinuation(key) } }
        }
    }

    private func dropContinuation(_ key: UUID) { stateContinuations[key] = nil }

    private func set(_ new: State) {
        state = new
        switch new {
        case .idle, .stopped, .failed: signpost.end()
        default: signpost.enter("coordinator step", String(describing: new).prefix(24).description)
        }
        OPLog.log(.runtime, .info, "coordinator → \(new)")
        recordMemory(label: String(describing: new).prefix(while: { $0 != "(" }).description)
        for c in stateContinuations.values {
            c.yield(new)
        }
    }

    /// Can this game launch right now, before any adapter is built?
    public func preflight(_ request: LaunchRequest) async -> LaunchPreflight {
        guard !restartRequired else { return .slotSpent(.spentByTeardown) }
        await restoreSpentIfNeeded()
        guard let runtimeID = request.resolution.selectedRuntime else { return .noRuntime(request.resolution.reason) }
        guard factories[runtimeID] != nil else { return .notBuilt(runtimeID) }
        switch await ledger.launchVerdict(for: runtimeID.slot, game: request.record.id.rawValue) {
        case .ready: return .ok
        case let .slotBusy(active): return .slotBusy(activeGame: GameID(active))
        case let .restartRequired(reason): return .slotSpent(reason)
        }
    }

    /// Reserves the coordinator before any await, so two launch requests cannot pass admission together.
    @discardableResult
    public func launch(_ request: LaunchRequest, host: any RuntimeHost) async throws -> ActiveSession {
        // A launch or stop that timed out keeps its task forever; say restart, not "still closing".
        guard !restartRequired else { throw CoordinatorError.preflight(.slotSpent(.spentByTeardown)) }
        guard state.isIdle, launchTask == nil, stopTask == nil else { throw CoordinatorError.busy }
        lastVerdict = .clean
        set(.preparing(request.record.id))
        let task = Task { try await self.prepareAndStart(request, host: host) }
        launchTask = task
        defer { launchTask = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func prepareAndStart(_ request: LaunchRequest, host: any RuntimeHost) async throws -> ActiveSession {
        let pre = await preflight(request)
        guard pre == .ok, let runtimeID = request.resolution.selectedRuntime, let factory = factories[runtimeID] else {
            set(.failed("preflight: \(pre)"))
            throw CoordinatorError.preflight(pre)
        }
        let session = ActiveSession(
            id: request.configuration.sessionID.rawValue,
            gameID: request.record.id,
            runtime: runtimeID,
            slot: runtimeID.slot,
            startedAt: .now
        )
        do {
            try await ledger.recordStart(of: session.slot, game: session.gameID.rawValue)
        } catch {
            set(.failed("slot reservation: \(error)"))
            throw CoordinatorError.busy
        }
        watchSystemOnce()
        startMemoryRecording(in: request.configuration.logDirectory)
        let marker = SessionMarker(directory: request.configuration.logDirectory)
        marker.write(game: session.gameID, runtime: "\(runtimeID)")
        self.marker = marker
        CrashGuard.setDirectory(request.configuration.logDirectory)
        try? store?.sessions.begin(SessionRecord(id: session.id, gameId: session.gameID, runtime: runtimeID))
        let adapter = await factory(request.configuration)
        runtime = adapter
        var preparing = true
        do {
            try Task.checkCancellation()
            try await adapter.prepare(configuration: request.configuration)
            try Task.checkCancellation()
            preparing = false
            set(.launching(session.gameID))
            try await adapter.start(in: host)
            try Task.checkCancellation()
            set(.running(session))
            return session
        } catch {
            let failure = error
            set(.stopping(session))
            let verdict = await RuntimeTeardown.wait {
                await adapter.stop(reason: .crash(detail: String(describing: failure)))
            }
            await finish(session, verdict: verdict, grade: nil, peak: nil, notes: "startup: \(failure)")
            set(.failed("\(preparing ? "prepare" : "start"): \(failure)"))
            if failure is CancellationError {
                throw CancellationError()
            }
            if preparing {
                throw CoordinatorError.prepareFailed(String(describing: failure))
            }
            throw CoordinatorError.startFailed(String(describing: failure))
        }
    }

    public func pause() async {
        guard case let .running(session) = state, let runtime else { return }
        await change(to: .paused(session)) { await runtime.pause() }
    }

    public func resume() async {
        guard case let .paused(session) = state, let runtime else { return }
        await change(to: .running(session)) { await runtime.resume() }
    }

    /// Applies `target` only if no other pause/resume or state change happened while `call` ran.
    private func change(to target: State, _ call: () async -> Void) async {
        let (revision, before) = (UUID(), state)
        lifecycleRevision = revision
        await call()
        guard lifecycleRevision == revision, state == before else { return }
        set(target)
    }

    /// Concurrent callers await the same teardown. A noncooperative runtime is retained until process restart.
    @discardableResult
    public func stop(reason: RuntimeStopReason, grade: PlayabilityGrade? = nil, peakFootprint: Int64? = nil) async -> TeardownVerdict {
        if let stopTask {
            return await stopTask.value
        }
        lifecycleRevision = UUID()
        let task = Task { await self.stopCurrent(reason: reason, grade: grade, peak: peakFootprint) }
        stopTask = task
        defer { stopTask = nil }
        return await task.value
    }

    private func stopCurrent(reason: RuntimeStopReason, grade: PlayabilityGrade?, peak: Int64?) async -> TeardownVerdict {
        // A launch already given up on never ends; waiting on it again only adds another timeout to every stop.
        if restartRequired, launchTask != nil {
            return .restartRequired
        }
        if let launchTask {
            launchTask.cancel()
            // The cancelled launch runs its own teardown under `stopTimeout` once it notices the cancellation, so this
            // outer deadline covers both; one `stopTimeout` would call a clean but slow teardown a hang.
            let verdict = await RuntimeTeardown.wait(timeout: Self.stopTimeout * 2) {
                _ = await launchTask.result
                return await self.lastVerdict
            }
            if verdict == .restartRequired {
                restartRequired = true
                stopMemoryRecording()
                // The launch is still stuck in the engine; observers get a terminal state instead of `.preparing`.
                set(.stopped(verdict))
            }
            // A launch can finish just before cancellation; then stop that running session below.
            if activeSession == nil {
                return verdict
            }
        }
        guard let session = activeSession, let runtime else { return restartRequired ? .restartRequired : lastVerdict }
        set(.stopping(session))
        let verdict = await RuntimeTeardown.wait { await runtime.stop(reason: reason) }
        await finish(session, verdict: verdict, grade: grade, peak: peak, notes: "\(reason)")
        set(.stopped(verdict))
        return verdict
    }

    private func finish(_ session: ActiveSession, verdict: TeardownVerdict, grade: PlayabilityGrade?, peak: Int64?, notes: String) async {
        lastVerdict = verdict
        if verdict == .restartRequired {
            restartRequired = true
            // Native callback userdata may still reference the adapter. Never free it or reuse the process.
        } else {
            runtime = nil
        }
        await ledger.recordStop(of: session.slot, game: session.gameID.rawValue, verdict: verdict)
        if verdict != .clean {
            for slot in session.slot.diesWith {
                try? store?.slots.markSpent(bootID: bootID, slot: slot, by: session.gameID)
            }
        }
        let peak = peak ?? (peakFootprint > 0 ? Int64(peakFootprint) : nil)
        try? store?.sessions.end(id: session.id, verdict: "\(verdict)", grade: grade, peakFootprint: peak, notes: notes)
        clearMarker()
        stopMemoryRecording()
    }

    /// Teardown ran, whatever its verdict, so the session is accounted for.
    private func clearMarker() {
        marker?.clear()
        marker = nil
        CrashGuard.setDirectory(nil)
    }

    // MARK: Memory around transitions (RUNTIME-009)

    /// One `memory.jsonl` per game session: a sample on every transition and every ten seconds in between.
    private func startMemoryRecording(in directory: URL) {
        let recorder = MemoryRecorder(fileURL: directory.appending(path: "memory.jsonl"))
        memory = recorder
        peakFootprint = 0
        memoryTask?.cancel()
        memoryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self else { return }
                await recordMemory(label: "tick", force: true)
            }
        }
    }

    private func recordMemory(label: String, force: Bool = true) {
        guard let memory else { return }
        let sample = MemoryProbe.sample(label: label)
        if let footprint = sample.footprintBytes, footprint > peakFootprint {
            peakFootprint = footprint
        }
        Task { await memory.record(sample, force: force) }
    }

    private func stopMemoryRecording() {
        systemWatch?.cancel()
        systemWatch = nil
        memoryTask?.cancel()
        memoryTask = nil
        memory = nil
    }

    /// Reports a runtime-side failure (crash, hang) and tears down.
    public func fail(_ detail: String) async {
        _ = await stop(reason: .crash(detail: detail))
        set(.failed(detail))
    }

    public func send(_ event: GameInputEvent) async {
        guard activeSession != nil, !restartRequired else { return }
        await runtime?.send(event)
    }

    /// 1 when off or unsupported, 2...9 while the engine is running fast.
    public var fastForward: Int {
        get async { await (activeRuntime as? FastForwardCapable)?.fastForward ?? 1 }
    }

    public func setFastForward(_ multiplier: Int) async {
        await (activeRuntime as? FastForwardCapable)?.setFastForward(multiplier)
    }

    /// True while the active adapter can be sped up, so the pause menu can hide the control otherwise.
    public var engineMenuTitle: String? {
        get async { await (activeRuntime as? EngineMenuCapable)?.engineMenuTitle }
    }

    /// The adapter's own picture of the game, for adapters that can draw one on request.
    public func captureScreen() async -> CGImage? {
        await (activeRuntime as? ScreenCapturing)?.captureScreen()
    }

    public func openEngineMenu() async {
        await (activeRuntime as? EngineMenuCapable)?.openEngineMenu()
    }

    /// The running game's typed state, when its runtime has a bridge.
    public var stateInspector: (any StateInspecting)? {
        get async { activeRuntime as? any StateInspecting }
    }

    /// The running adapter, when it can take live translations.
    public var liveTranslationHost: (any LiveTranslationHost)? {
        get async { activeRuntime as? any LiveTranslationHost }
    }

    /// The pause menu's speed row, nil when the active adapter cannot go faster.
    public var speedChoices: SpeedChoices? {
        get async {
            let choices = await (activeRuntime as? FastForwardCapable)?.speedChoices
            return choices?.options.isEmpty == false ? choices : nil
        }
    }

    /// Memory pressure goes to the running adapter. The watch ends with the session.
    private func watchSystemOnce() {
        guard systemWatch == nil else { return }
        systemWatch = Task { [weak self] in
            for await level in MemoryPressureMonitor.levels() {
                await self?.activeRuntime?.handleMemoryPressure(level)
            }
        }
    }

    /// The session in `.running` or `.paused`, if any.
    public var activeSession: ActiveSession? {
        switch state {
        case let .running(s), let .paused(s): s
        default: nil
        }
    }

    private var activeRuntime: (any GameRuntime)? { activeSession != nil && !restartRequired ? runtime : nil }

    /// True while an adapter object is retained (tests assert release after stop).
    public var holdsRuntime: Bool { runtime != nil }
}
