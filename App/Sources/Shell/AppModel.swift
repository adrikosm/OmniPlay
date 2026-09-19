import Diagnostics
import GameCore
import GameDetection
import GameImport
import GameStore
import InputKit
import OverlayVFS
import RuntimeCore
import SaveKit
import SwiftUI

enum AppTab: Hashable { case library, importGames, settings }

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
    /// The running session's log file, for the pause menu's log viewer.
    private(set) var sessionLog: URL?
    private(set) var isPaused = false
    /// One line for the player about media that cannot play yet, set when a session starts.
    private(set) var launchNotice: String?

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
                try paths.ensureLayout()
                let store = try GameStore.open(paths: paths)
                ImportCoordinator.sweepStaleStaging(paths: paths, olderThan: 0) // nothing can be in flight at launch
                Self.sweepOrphans(paths: paths, store: store)
                return .success(store)
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case let .success(store):
            self.store = store
            let coordinator = RuntimeCoordinator(store: store)
            await coordinator.register(.web) { _ in WebRuntime() }
            await registry.register(.init(
                id: .web,
                families: [.rpgMakerMV, .rpgMakerMZ, .html5, .unityWeb, .godotWeb, .flash],
                generations: [.mv, .mz],
                version: "WebKit",
                flags: [.saves, .persistentData, .screenshot],
                availability: .bundled
            ))
            self.coordinator = coordinator
            imports = ImportsModel(
                coordinator: importer,
                pipeline: ImportPipeline(paths: paths, store: store, session: HostSession.shared.sessionID, registry: registry)
            )
            phase = .ready
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
                if let path = DebugLaunch.value(for: "--import") {
                    await imports?.enqueue(URL(filePath: path))
                }
            #endif
            OPLog.log(.ui, .info, "app ready", session: HostSession.shared.sessionID)
        case let .failure(error):
            phase = .storeFailed(String(describing: error))
            OPLog.log(.ui, .fault, "store failed to open: \(error)", session: HostSession.shared.sessionID)
        }
    }

    /// Removes `Games/<id>` directories without a library row: leftovers of a commit that failed mid-way.
    nonisolated static func sweepOrphans(paths: AppPaths, store: GameStore) {
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: paths.games(), includingPropertiesForKeys: nil),
              let known = try? store.games.fetchAll(limit: 100_000).map(\.id.description) else { return }
        let knownSet = Set(known)
        for dir in dirs where !knownSet.contains(dir.lastPathComponent) {
            try? OriginalGuard.unseal(originalRoot: dir.appending(path: "Original"))
            try? FileManager.default.removeItem(at: dir)
            OPLog.log(.importer, .default, "removed orphan game directory \(dir.lastPathComponent)")
        }
    }

    /// The stored detection report and resolution for a game, read off the main actor.
    nonisolated static func snapshot(for id: GameID, paths: AppPaths) -> DetectionSnapshot? {
        let url = paths.logs(game: id, session: UUID()).deletingLastPathComponent().appending(path: "detection.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DetectionSnapshot.self, from: data)
    }

    /// Re-resolves a stored report against the runtimes this build actually has (a game imported before
    /// a runtime landed keeps its report; only the choice is refreshed).
    func freshResolution(for record: GameRecord, snapshot: DetectionSnapshot) async -> RuntimeResolution {
        await RuntimeResolver(registry: registry).resolve(snapshot.report, override: record.manualRuntimeOverride)
    }

    /// Starts a session for `record` inside `host`. Throws with a message fit for the player.
    func play(_ record: GameRecord, snapshot: DetectionSnapshot, host: any RuntimeHost) async throws -> ActiveSession {
        guard let coordinator, let store else { throw CoordinatorError.busy }
        let resolution = await freshResolution(for: record, snapshot: snapshot)
        var descriptor = snapshot.report.descriptor.withID(record.id)
        descriptor.profile = resolution.profile
        // Big MZ titles get an image-cache cap unless the player set one; smaller ones keep the engine's behaviour.
        if descriptor.engine == .rpgMakerMZ, record.installBytes > 1 << 30, descriptor.profile.overrides["imageCacheCapMB"] == nil {
            descriptor.profile.overrides["imageCacheCapMB"] = "256"
        }
        // Hints a previous session left (the loopback port keeps the web storage origin stable).
        for row in (try? store.overrides.all(game: record.id)) ?? [] where row.key.hasPrefix("hint.") {
            descriptor.profile.overrides[String(row.key.dropFirst(5))] = row.valueJson
        }
        let configuration = RuntimeConfiguration.forGame(descriptor, paths: paths, profile: descriptor.profile, sidecars: [])
        let request = LaunchRequest(record: record, descriptor: descriptor, resolution: resolution, configuration: configuration)
        let plan = MediaPlan(requirements: descriptor.mediaRequirements)
        launchNotice = plan.notice
        recordPendingTranscodes(plan.pendingTranscodes, game: record.id, runtime: resolution.selectedRuntime)
        let saves = SaveLocation.forGame(record.id, paths: paths)
        if SaveVault.hasContent(saves) {
            _ = try? await SaveVault.snapshot(location: saves, identityHash: descriptor.identityHash, reason: .beforeLaunch)
            SaveVault.prune(location: saves, keep: SaveVault.retention(from: descriptor.profile.overrides))
        }
        OPLog.beginSession(configuration.sessionID, directory: configuration.logDirectory)
        sessionLog = configuration.logDirectory.appending(path: "host.log")
        let session: ActiveSession
        do {
            session = try await coordinator.launch(request, host: host)
        } catch {
            await OPLog.endSession(configuration.sessionID)
            throw error
        }
        playing = descriptor
        isPaused = false
        var updated = record
        updated.lastPlayedAt = .now
        try? store.games.update(updated)
        return session
    }

    /// Rebuilds the save index for a game after a manual import or restore.
    func reindexSaves(_ id: GameID) {
        if let descriptor = Self.snapshot(for: id, paths: paths)?.report.descriptor.withID(id) {
            indexSaves(for: descriptor)
        }
    }

    func stopPlaying(reason: RuntimeStopReason = .userExit) async {
        let session = await coordinator?.activeSession
        _ = await coordinator?.stop(reason: reason)
        if let playing {
            indexSaves(for: playing)
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
        isPaused = true
    }

    func resume() async {
        await coordinator?.resume()
        isPaused = false
    }

    /// Persists a runtime hint under `hint.<key>` so the next launch of this game sees it in its profile.
    func remember(hint key: String, value: String, for id: GameID) {
        try? store?.overrides.set(game: id, key: "hint.\(key)", valueJson: value)
    }

    func send(_ event: GameInputEvent) {
        guard let coordinator else { return }
        Task { await coordinator.send(event) }
    }

    /// Transcodes the media pipeline (Epic 16) will run; recorded once per file so the queue survives relaunches.
    private func recordPendingTranscodes(_ requirements: [MediaRequirement], game: GameID, runtime: RuntimeIdentifier?) {
        guard let store, !requirements.isEmpty else { return }
        let known = Set(((try? store.fetchAll(MediaJobRecord.self, game: game)) ?? []).map(\.inputRel))
        for r in requirements where !known.contains(r.sourceRel) {
            guard case let .transcode(target) = r.action else { continue }
            let stem = r.sourceRel.split(separator: ".").dropLast().joined(separator: ".")
            let container = target.split(separator: "/").first.map(String.init) ?? "mp4"
            _ = try? store.insert(MediaJobRecord(
                gameId: game,
                inputRel: r.sourceRel,
                outputRel: "\(stem).\(container)",
                sourceCodec: r.videoCodec ?? r.container,
                targetCodec: target,
                targetRuntime: runtime.map { "\($0)" } ?? "web",
                reason: "runtime cannot decode \(r.videoCodec ?? r.container) in \(r.container)",
                state: "pending"
            ))
        }
    }

    /// Rebuilds `saves_meta` from the slot files so the library can show what a game has saved.
    func indexSaves(for descriptor: GameDescriptor) {
        guard let store else { return }
        let location = SaveLocation.forGame(descriptor.id, paths: paths)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: location.slots,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        )) ?? []
        let records = files.filter { !$0.lastPathComponent.hasPrefix(".") }.map { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let stem = url.deletingPathExtension().lastPathComponent
            return SaveMetaRecord(
                gameId: descriptor.id,
                slotKey: SaveKey.decodeWebStorage(stem) ?? stem,
                relPath: "Saves/slots/\(url.lastPathComponent)",
                family: descriptor.saveFamily.rawValue,
                bytes: Int64(values?.fileSize ?? 0),
                modifiedAt: values?.contentModificationDate ?? .now,
                provenanceHash: descriptor.identityHash
            )
        }
        try? store.saves.replaceAll(game: descriptor.id, with: records)
        let kinds = SaveStrategy.forEngine(descriptor.engine, generation: descriptor.generation).persistentStores
            .compactMap { PersistentStoreKind(rawValue: $0.rawValue) }
        let stores = PersistentStoreRegistry.stores(location: location, kinds: kinds).filter(\.isPresent).map {
            PersistentStoreRecord(
                gameId: descriptor.id,
                kind: $0.kind.rawValue,
                relPath: paths.stored($0.directory),
                bytes: $0.bytes,
                modifiedAt: $0.modifiedAt ?? .now
            )
        }
        try? store.persistentStores.replaceAll(game: descriptor.id, with: stores)
    }

    /// Stores a per-game runtime choice, re-resolves against it and persists the new selection.
    func chooseRuntime(_ runtime: RuntimeIdentifier?, for id: GameID) async -> RuntimeResolution? {
        guard let store, var snapshot = Self.snapshot(for: id, paths: paths) else { return nil }
        let value = runtime.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) }
        try? store.overrides.set(game: id, key: "runtime", valueJson: value ?? "null")
        snapshot.resolution = await RuntimeResolver(registry: registry).resolve(snapshot.report, override: runtime)
        let url = paths.logs(game: id, session: UUID()).deletingLastPathComponent().appending(path: "detection.json")
        try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        if var record = try? store.games.fetch(id: id) {
            record.runtime = snapshot.resolution.selectedRuntime
            record.manualRuntimeOverride = runtime
            try? store.games.update(record)
        }
        if let selected = snapshot.resolution.selectedRuntime {
            _ = try? store.runtime.saveSelection(.init(gameId: id, selectedRuntime: selected, reason: snapshot.resolution.reason))
        }
        return snapshot.resolution
    }

    /// Deletes only the library database; game files under `Games/` are untouched. Then relaunches.
    func resetLibraryDatabase() async {
        phase = .launching
        let db = paths.database().deletingLastPathComponent()
        try? FileManager.default.removeItem(at: db)
        await launch()
    }
}

#if DEBUG
    /// Launch arguments used by the simulator review scripts; compiled out of release builds.
    enum DebugLaunch {
        static func value(for flag: String) -> String? {
            let args = ProcessInfo.processInfo.arguments
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        static var openFirstGame: Bool { ProcessInfo.processInfo.arguments.contains("--open-first-game") || playFirstGame }
        static var playFirstGame: Bool { ProcessInfo.processInfo.arguments.contains("--play-first-game") }
        static var openPauseMenu: Bool { ProcessInfo.processInfo.arguments.contains("--open-pause-menu") }
    }
#endif
