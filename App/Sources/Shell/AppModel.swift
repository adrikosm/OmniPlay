import Diagnostics
import GameCore
import GameDetection
import GameImport
import GameStore
import GameTools
import InputKit
import OverlayVFS
import RGSSRuntime
import RuntimeCore
import SaveKit
import SwiftUI

enum AppTab: Hashable { case library, importGames, settings, search }

/// App-wide state: storage paths, the library database, the import coordinator, and which tab is up.
/// Launch work runs off the main actor; the UI shows an overlay when it takes longer than 300 ms.
@Observable @MainActor
final class AppModel {
    enum Phase: Equatable {
        case launching
        case ready
        case storeFailed(String)
    }

    let paths: AppPaths
    private(set) var phase: Phase = .launching
    private(set) var store: GameStore?
    private(set) var importer: ImportCoordinator
    private(set) var imports: ImportsModel?
    let registry = RuntimeRegistry()
    private(set) var coordinator: RuntimeCoordinator?
    var selectedTab: AppTab = .library
    /// The game a session is running for, kept so the save index can be rebuilt when it ends.
    private(set) var playing: GameDescriptor?
    /// The running session's Game Tools changes (validation, backup, undo), when its runtime has a state bridge.
    private(set) var tools: MutationEngine?
    /// The running session's log file, for the pause menu's log viewer.
    private(set) var sessionLog: URL?
    private(set) var isPaused = false
    /// One line for the player about something missing (art, music, media), set when a session starts.
    private(set) var launchNotice: String?
    /// Progress while a game's media is converted before it starts (`AppModel+Media`).
    var preparingMedia: MediaStatus?
    @ObservationIgnored private(set) var mediaCancel = MediaCancel()
    @ObservationIgnored private var playTask: Task<ActiveSession, Error>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var inputGeneration = UUID()
    /// Engine slots spent in this app launch; games on them show "Restart needed" before Play.
    private(set) var spentSlots: Set<SessionSlot> = []
    /// A game to open right after launch, left by Save & Relaunch.
    private(set) var pendingOpen: GameID?
    /// What a native runtime reported going wrong mid-session; the player screen shows it.
    var runtimeFailure: String?
    /// A failed or unconfirmed web save, retained until the player acknowledges it when leaving.
    var saveWarning: String?
    /// Something the running game went through that the player should hear about (a web page reloaded after its
    /// process died); the player screen shows it briefly and clears it.
    var runtimeNotice: String?
    @ObservationIgnored private var inputTail: Task<Void, Never>?
    @ObservationIgnored private var keyDownAt: [GameKey: ContinuousClock.Instant] = [:]
    /// Games that already had their one automatic runtime fallback this launch (RUNTIME-007).
    @ObservationIgnored var fallbackTried: Set<GameID> = []
    /// The playing session's controller capture, so a changed controller map applies at once.
    @ObservationIgnored weak var activeCapture: ControllerCapture?
    /// While set, controller buttons go here instead of the game: the mapping screen finding a button.
    @ObservationIgnored var controllerListener: (@MainActor (ControllerButton) -> Void)?
    /// The sibling runtime a game is being retried on, until it plays through the boot window or fails.
    @ObservationIgnored var pendingFallback: [GameID: RuntimeIdentifier] = [:]
    /// Games whose last session ended without teardown (a crash or a kill mid-game), named once after launch.
    var unexpectedEnds: [String] = []

    init(paths: AppPaths = HostSession.shared.paths) {
        self.paths = paths
        importer = ImportCoordinator(paths: paths)
        #if DEBUG
            switch DebugLaunch.value(for: "--tab") {
            case "import": selectedTab = .importGames
            case "settings": selectedTab = .settings
            default: break
            }
        #endif
    }

    func launch() async {
        let paths = paths
        let result = await Task.detached(priority: .userInitiated) { () -> Result<GameStore, Error> in
            do {
                #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--reset-library") {
                        Self.resetLibrary(paths: paths)
                    }
                #endif
                try paths.ensureLayout()
                let store = try GameStore.open(paths: paths)
                ImportCoordinator.sweepStaleStaging(paths: paths, olderThan: 0) // nothing can be in flight at launch
                // A missing database row does not make a game disposable: recovery can recreate the
                // database while the original, saves and backups still belong to the player.
                return .success(store)
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case let .success(store):
            let coordinator = RuntimeCoordinator(store: store, bootID: HostSession.shared.sessionID.description)
            await coordinator.register(.web) { [weak self] _ in
                let runtime = WebRuntime()
                runtime.onFailure = { message in self?.runtimeFailure = message }
                runtime.onSaveFailure = { message in self?.saveWarning = self?.saveWarning ?? message }
                runtime.onNotice = { message in self?.runtimeNotice = message }
                return runtime
            }
            await registry.register(.init(
                id: .web,
                // KiriKiri plays in the web view through KrKr2 Web when this build carries it.
                families: [.rpgMakerMV, .rpgMakerMZ, .html5, .unityWeb, .godotWeb, .flash] +
                    (KiriKiriWeb.engineRoot() != nil ? [.kirikiri] : []),
                generations: [.mv, .mz],
                version: "WebKit",
                flags: [.saves, .persistentData, .screenshot],
                availability: .bundled
            ))
            await registerRGSS(with: coordinator)
            await registerRenPy(with: coordinator)
            await registerEasyRPG(with: coordinator)
            await registerScummVM(with: coordinator)
            await registerGodot(with: coordinator)
            self.coordinator = coordinator
            imports = ImportsModel(
                coordinator: importer,
                pipeline: ImportPipeline(paths: paths, store: store, session: HostSession.shared.sessionID, registry: registry)
            )
            // Publishing the store starts library observation and may trigger a pending game launch.
            self.store = store
            phase = .ready
            reportUnfinishedSessions()
            Task { await self.repairPluginRefusals(store: store) }
            pendingOpen = Self.consumeRelaunchRequest(paths: paths)
            #if DEBUG
                OPLog.log(
                    .ui,
                    .debug,
                    "launch arguments: \(ProcessInfo.processInfo.arguments.dropFirst())",
                    session: HostSession.shared.sessionID
                )
                LogRetention.sweep(logsRoot: paths.logsRoot())
                if ProcessInfo.processInfo.arguments.contains("--sample-library") {
                    SampleLibrary.insert(into: store)
                }
                // A relative path is under Documents: on the phone, games are copied into the app's own container.
                if let path = DebugLaunch.value(for: "--import") {
                    await imports?.enqueue(path.hasPrefix("/") ? URL(filePath: path) : URL.documentsDirectory.appending(path: path))
                }
            #endif
            OPLog.log(.ui, .info, "app ready", session: HostSession.shared.sessionID)
        case let .failure(error):
            phase = .storeFailed(String(describing: error))
            OPLog.log(.ui, .fault, "store failed to open: \(error)", session: HostSession.shared.sessionID)
        }
    }

    /// What tapping Play would do, before tapping it (§14.2: the user sees "Restart needed" first).
    func preflight(_ record: GameRecord, snapshot: DetectionSnapshot) async -> LaunchPreflight? {
        guard let coordinator else { return nil }
        let resolution = await freshResolution(for: record, snapshot: snapshot)
        let descriptor = snapshot.report.descriptor.withID(record.id)
        let configuration = RuntimeConfiguration.forGame(descriptor, paths: paths, profile: resolution.profile, sidecars: [])
        let verdict = await coordinator.preflight(LaunchRequest(
            record: record,
            descriptor: descriptor,
            resolution: resolution,
            configuration: configuration
        ))
        spentSlots = await coordinator.spentSlots()
        return verdict
    }

    func clearPendingOpen() { pendingOpen = nil }

    /// Shows a game's page from elsewhere in the app (an import that just finished).
    func open(_ id: GameID) {
        pendingOpen = id
        selectedTab = .library
    }

    /// Starts a session for `record` inside `host`. Throws with a message fit for the player.
    func play(_ record: GameRecord, snapshot: DetectionSnapshot, host: any RuntimeHost) async throws -> ActiveSession {
        // A launch the coordinator gave up on never returns, so playTask stays set: that needs a restart, not a retry.
        if await coordinator?.restartRequired == true {
            throw CoordinatorError.preflight(.slotSpent(.spentByTeardown))
        }
        guard playTask == nil, stopTask == nil, playing == nil else { throw CoordinatorError.busy }
        mediaCancel = MediaCancel()
        saveWarning = nil
        let task = Task { try await self.prepareAndPlay(record, snapshot: snapshot, host: host) }
        playTask = task
        defer { playTask = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func prepareAndPlay(_ record: GameRecord, snapshot: DetectionSnapshot, host: any RuntimeHost) async throws -> ActiveSession {
        guard let coordinator, let store else { throw CoordinatorError.busy }
        try Task.checkCancellation()
        let resolution = await freshResolution(for: record, snapshot: snapshot)
        try Task.checkCancellation()
        var descriptor = launchDescriptor(record, snapshot: snapshot, resolution: resolution, store: store)
        // Whatever the engine cannot decode is converted first; the runtime gets the old names mapped onto the new.
        let original = LayerSetBuilder.forGame(descriptor, paths: paths).first { $0.tier == .original }?.root
            ?? paths.tier(.original, for: record.id)
        let media = await prepareMedia(
            for: record.id,
            runtime: resolution.selectedRuntime,
            gameRoot: original,
            indexURL: paths.game(record.id).appending(path: "index.sqlite")
        )
        try Task.checkCancellation()
        if mediaCancel.isSet {
            throw CancellationError()
        }
        if !media.remap.isEmpty, let json = try? JSONEncoder().encode(media.remap), let text = String(bytes: json, encoding: .utf8) {
            descriptor.profile.overrides["mediaRemap"] = text
        }
        // Mods apply at launch: their folders are indexed and MV/MZ plugin lists composed before the runtime starts.
        await prepareMods(for: descriptor, gameRoot: original)
        try Task.checkCancellation()
        await prepareTranslations(for: descriptor.id, profile: &descriptor.profile)
        try Task.checkCancellation()
        let configuration = RuntimeConfiguration.forGame(
            descriptor, paths: paths, profile: descriptor.profile,
            sidecars: modSublayers(for: descriptor.id) + translationSublayers(for: descriptor.id)
        )
        let request = LaunchRequest(record: record, descriptor: descriptor, resolution: resolution, configuration: configuration)
        // One line, in the order the player would care: missing art, then missing music, then media.
        launchNotice = [
            RTPManager.explanation(for: RTPManager.status(for: descriptor, paths: paths)),
            MIDISoundFont.notice(for: descriptor, paths: paths),
            media.failed > 0 ? "\(media.failed) media files could not be converted; the session log says why." : nil,
        ].compactMap(\.self).first
        let saves = SaveLocation.forGame(record.id, paths: paths)
        if SaveVault.hasContent(saves) {
            _ = try? await SaveVault.snapshot(location: saves, identityHash: descriptor.identityHash, reason: .beforeLaunch)
            SaveVault.prune(location: saves, keep: SaveVault.retention(from: descriptor.profile.overrides))
        }
        try Task.checkCancellation()
        OPLog.beginSession(configuration.sessionID, directory: configuration.logDirectory)
        sessionLog = configuration.logDirectory.appending(path: "host.log")
        let session: ActiveSession
        do {
            session = try await coordinator.launch(request, host: host)
            try Task.checkCancellation()
        } catch {
            await OPLog.endSession(configuration.sessionID)
            throw error
        }
        playing = descriptor
        isPaused = false
        await startLiveTranslation(descriptor)
        if let inspector = await coordinator.stateInspector, !Task.isCancelled {
            let identity = descriptor.identityHash
            tools = MutationEngine(inspector: inspector) {
                _ = try await SaveVault.snapshot(location: saves, identityHash: identity, reason: .beforeEdit)
            }
        }
        #if DEBUG
            // Containment checks: a crash mid-session must leave a marker for the next launch and, on a device,
            // a MetricKit report.
            if let delay = DebugLaunch.value(for: "--debug-crash-in-game").flatMap(Double.init) {
                Task {
                    try? await Task.sleep(for: .seconds(delay))
                    fatalError("crash requested by --debug-crash-in-game")
                }
            }
        #endif
        try Task.checkCancellation()
        var updated = record
        updated.lastPlayedAt = .now
        try? store.games.update(updated)
        return session
    }

    func stopPlaying(reason: RuntimeStopReason = .userExit) async {
        if let stopTask {
            await stopTask.value; return
        }
        cancelMediaPreparation()
        playTask?.cancel()
        inputGeneration = UUID()
        inputTail?.cancel()
        inputTail = nil
        keyDownAt.removeAll()
        tools?.stop()
        tools = nil
        let task = Task { await self.finishPlaying(reason: reason) }
        stopTask = task
        defer { stopTask = nil }
        await task.value
    }

    private func finishPlaying(reason: RuntimeStopReason) async {
        let session = await coordinator?.activeSession
        _ = await coordinator?.stop(reason: reason)
        if let playing {
            indexSaves(for: playing)
            // A script insert Ren'Py could not load is switched off before the next launch.
            if playing.engine == .renpy, let logs = sessionLog?.deletingLastPathComponent() {
                await disableFailedInserts(game: playing.id, logDirectory: logs)
            }
        }
        if let coordinator {
            spentSlots = await coordinator.spentSlots()
        }
        if let session {
            await OPLog.endSession(SessionID(rawValue: session.id))
        }
        playing = nil
        isPaused = false
        let logs = paths.logsRoot()
        Task.detached(priority: .utility) { LogRetention.sweep(logsRoot: logs) }
    }

    func pause() async {
        await coordinator?.pause()
        if case .paused = await coordinator?.state {
            isPaused = true
        }
    }

    func resume() async {
        await coordinator?.resume()
        if case .running = await coordinator?.state {
            isPaused = false
        }
    }

    /// Input reaches the engine in the order it happened, and no press is shorter than `minimumPress`: engines read
    /// keys once per frame (and several times per frame when fast-forwarding), so a quick thumb tap whose down and
    /// up land between two reads was lost. Only the release waits; the next press still starts immediately after it.
    func send(_ event: GameInputEvent) {
        guard let coordinator, playing != nil, stopTask == nil else { return }
        let generation = inputGeneration
        var wait: Duration = .zero
        switch event {
        case let .keyDown(key): keyDownAt[key] = .now
        case let .keyUp(key):
            if let at = keyDownAt.removeValue(forKey: key) {
                wait = Self.minimumPress - (ContinuousClock.now - at)
            }
        default: break
        }
        let previous = inputTail
        inputTail = Task {
            await previous?.value
            guard !Task.isCancelled, generation == inputGeneration else { return }
            if wait > .zero {
                do { try await Task.sleep(for: wait) } catch { return }
            }
            guard generation == inputGeneration else { return }
            await coordinator.send(event)
        }
    }

    static let minimumPress: Duration = .milliseconds(100)

    // Sessions from a previous launch whose teardown never ran: a crash, a kill from the app switcher, or a
    // hang the player escaped. The marker is left where the session's own logs are, so naming it here points
    // at the bundle that explains it.

    /// Deletes only the library database; game files under `Games/` are untouched. Then relaunches.
    func resetLibraryDatabase() async {
        phase = .launching
        let db = paths.database().deletingLastPathComponent()
        try? FileManager.default.removeItem(at: db)
        await launch()
    }
}
