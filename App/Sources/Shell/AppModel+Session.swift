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

/// Per-game hints and runtime choices, and what the running session can be asked.
extension AppModel {
    /// Rebuilds the save index for a game after a manual import or restore.
    func reindexSaves(_ id: GameID) {
        if let descriptor = Self.snapshot(for: id, paths: paths)?.report.descriptor.withID(id) {
            indexSaves(for: descriptor)
        }
    }

    /// Persists a runtime hint under `hint.<key>` so the next launch of this game sees it in its profile.
    func remember(hint key: String, value: String, for id: GameID) {
        try? store?.overrides.set(game: id, key: "hint.\(key)", valueJson: value)
    }

    func hint(_ key: String, for id: GameID) -> String? {
        (try? store?.overrides.get(game: id, key: "hint.\(key)")).flatMap(\.self).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The low-memory profile: a small image cache and 1x canvases. Off restores the engine's defaults.
    func setLowMemory(_ on: Bool, for id: GameID) {
        remember(hint: "imageCacheCapMB", value: on ? "128" : "", for: id)
        remember(hint: "devicePixelRatio", value: on ? "1" : "", for: id)
    }

    func isLowMemory(_ id: GameID) -> Bool { hint("devicePixelRatio", for: id) == "1" }

    /// Stores a per-game runtime choice, re-resolves against it and persists the new selection.
    func chooseRuntime(_ runtime: RuntimeIdentifier?, for id: GameID) async -> RuntimeResolution? {
        guard let store, var snapshot = Self.snapshot(for: id, paths: paths) else { return nil }
        let value = runtime.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) }
        try? store.overrides.set(game: id, key: "runtime", valueJson: value ?? "null")
        snapshot.resolution = await RuntimeResolver(registry: registry).resolve(snapshot.report, override: runtime)
        let url = Self.detectionFile(for: id, paths: paths)
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

    enum RecheckResult {
        /// An import, a replacement or a deletion holds the game.
        case busy
        case checked(wasPlayable: Bool, snapshot: DetectionSnapshot, filesAdded: Int)
    }

    /// Looks at an installed game's files again: unpacks what import-time preparation would unpack today (a Tauri
    /// frontend inside the program), then runs detection again. The player's runtime choice is kept. Nil when the game
    /// is no longer in the library.
    func recheck(_ id: GameID) async throws -> RecheckResult? {
        guard let store, let record = try store.games.fetch(id: id) else { return nil }
        guard ImportPipeline.claim(id) else { return .busy }
        defer { ImportPipeline.release(id) }
        let paths = paths
        let previous = Self.snapshot(for: id, paths: paths)
        let (added, report) = try await Task.detached { () throws -> (Int, DetectionReport) in
            let gameRoot = paths.game(id)
            let original = paths.tier(.original, for: id)
            let root = record.rootRelPath.isEmpty ? original : original.appending(path: record.rootRelPath, directoryHint: .isDirectory)
            let added = try ProgramFrontends.unpackInstalled(
                original: original,
                indexRoot: root,
                manifest: gameRoot.appending(path: "original.manifest"),
                index: gameRoot.appending(path: "index.sqlite"),
                scratch: gameRoot.appending(path: ".recheck-\(UUID().uuidString)", directoryHint: .isDirectory),
                limits: .default
            )
            let sidecars = (try? Data(contentsOf: gameRoot.appending(path: "sidecars.json")))
                .flatMap { try? JSONDecoder().decode(ImportSidecars.self, from: $0) } ?? ImportSidecars()
            let ctx = try ScanContext(root: root, sidecars: sidecars)
            defer { ctx.close() }
            var report = DetectionPipeline.standard.run(
                ctx,
                title: record.title,
                identityHash: previous?.report.descriptor.identityHash ?? "",
                rootRelativePath: record.rootRelPath
            )
            report.detectorVersions["prep"] = ProgramFrontends.prepVersion
            return (added, report)
        }.value
        if added > 0 {
            ImportPipeline(paths: paths, store: store, session: HostSession.shared.sessionID, registry: registry).completeHashingLater(id)
        }
        let resolution = await RuntimeResolver(registry: registry).resolve(report, override: record.manualRuntimeOverride)
        let snapshot = DetectionSnapshot(report: report, resolution: resolution)
        let url = Self.detectionFile(for: id, paths: paths)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        var updated = record
        updated.engine = report.descriptor.engine
        updated.generation = report.descriptor.generation
        updated.version = report.descriptor.version?.raw
        updated.runtime = resolution.selectedRuntime
        updated.runtimeVersion = resolution.selectedRuntimeVersion
        updated.detectionConfidence = report.confidence
        updated.compatibilityState = report.outcome.isPlayableClass ? .loadable : .refused
        updated.compatProfileJson = report.descriptor.profile
        if updated.artworkPath == nil {
            updated.artworkPath = CoverExtractor.extract(
                game: id,
                engine: report.descriptor.engine,
                rootRelativePath: record.rootRelPath,
                paths: paths
            )
        }
        try store.games.update(updated)
        _ = try store.detection.saveResult(DetectionResultRecord(
            gameId: id,
            outcome: ImportPipeline.outcomeName(report.outcome),
            confidence: report.confidence,
            evidence: report.evidence.map(\.record),
            detectorVersions: report.detectorVersions.mapValues(String.init)
        ))
        if let selected = resolution.selectedRuntime {
            _ = try? store.runtime.saveSelection(.init(gameId: id, selectedRuntime: selected, reason: resolution.reason))
        }
        // New files or another runtime can mean media the old plan never converted.
        if added > 0 || resolution.selectedRuntime != previous?.resolution.selectedRuntime {
            prepareMediaInBackground(for: id)
        }
        let old = previous.map { ImportPipeline.outcomeName($0.report.outcome) } ?? "none"
        OPLog.log(
            .ui,
            .info,
            "re-checked \(record.title): \(old) -> \(ImportPipeline.outcomeName(report.outcome)), \(added) files added",
            session: HostSession.shared.sessionID
        )
        return .checked(wasPlayable: record.compatibilityState != .refused, snapshot: snapshot, filesAdded: added)
    }

    /// Every version a report written by this build carries: the detectors', the analyzers' and import preparation's.
    nonisolated static var currentDetectionVersions: [String: Int] {
        var versions = DetectionPipeline.standard.versions
        versions["prep"] = ProgramFrontends.prepVersion
        return versions
    }

    /// Once per app update: re-checks, one at a time, each game whose stored report was written with other detector or
    /// preparation versions. Only a clean re-check writes the new versions, so a pass the app is killed in resumes at
    /// the next launch. Games that became playable are announced on the Library.
    func recheckLibrary(store: GameStore) async {
        let paths = paths
        let current = Self.currentDetectionVersions
        let due = await Task.detached(priority: .utility) {
            ((try? store.games.fetchAll(limit: 10000)) ?? []).filter { Self.snapshot(for: $0.id, paths: paths)?.report.detectorVersions != current }
        }.value
        var playable: [GameRecord] = []
        for game in due where game.id != playing?.id {
            do {
                if case let .checked(wasPlayable, snapshot, _)? = try await recheck(game.id), !wasPlayable,
                   snapshot.report.outcome.isPlayableClass, let record = try store.games.fetch(id: game.id) {
                    playable.append(record)
                }
            } catch {
                OPLog.log(.ui, .error, "re-check of \(game.title) failed: \(error)", session: HostSession.shared.sessionID)
            }
        }
        if !playable.isEmpty {
            nowPlayable = playable
        }
    }

    /// The stored detection report and resolution for a game, read off the main actor. A report from before plugins
    /// stopped refusing games reads as it would be detected today.
    /// The detected identity hash save backups are keyed by, or the game id before detection has run.
    nonisolated static func identityHash(for id: GameID, paths: AppPaths) -> String {
        snapshot(for: id, paths: paths)?.report.descriptor.identityHash ?? id.description
    }

    /// `Logs/<game>/detection.json`: the stored detection report and runtime resolution.
    nonisolated static func detectionFile(for id: GameID, paths: AppPaths) -> URL {
        paths.logsRoot().appending(path: id.description, directoryHint: .isDirectory).appending(path: "detection.json")
    }

    nonisolated static func snapshot(for id: GameID, paths: AppPaths) -> DetectionSnapshot? {
        let url = Self.detectionFile(for: id, paths: paths)
        guard let data = try? Data(contentsOf: url), var snapshot = try? JSONDecoder().decode(DetectionSnapshot.self, from: data)
        else { return nil }
        snapshot.report = snapshot.report.liftingPluginBlockers()
        return snapshot
    }

    /// Re-resolves a stored report against the runtimes this build actually has (a game imported before
    /// a runtime landed keeps its report; only the choice is refreshed). The runtime choice is read from the stored
    /// row: a page's `record` may predate the player changing it.
    func freshResolution(for record: GameRecord, snapshot: DetectionSnapshot) async -> RuntimeResolution {
        let stored = (try? store?.games.fetch(id: record.id)) ?? record
        return await RuntimeResolver(registry: registry).resolve(
            snapshot.report,
            override: pendingFallback[record.id] ?? stored.manualRuntimeOverride
        )
    }

    /// The descriptor a launch runs with: the detection's, with the resolution's profile, a cache cap for big MZ
    /// games, the hints earlier sessions left, the Runtime page's choices and the soundfont for MIDI-era engines.
    func launchDescriptor(
        _ record: GameRecord,
        snapshot: DetectionSnapshot,
        resolution: RuntimeResolution,
        store: GameStore
    ) -> GameDescriptor {
        var descriptor = snapshot.report.descriptor.withID(record.id)
        descriptor.profile = resolution.profile
        // Big MZ titles get an image-cache cap unless the player set one; smaller ones keep the engine's behaviour.
        if descriptor.engine == .rpgMakerMZ, record.installBytes > 1 << 30, descriptor.profile.overrides["imageCacheCapMB"] == nil {
            descriptor.profile.overrides["imageCacheCapMB"] = "256"
        }
        // Hints a previous session left (the loopback port keeps the web storage origin stable).
        for row in (try? store.overrides.all(game: record.id)) ?? [] where row.key.hasPrefix("hint.") && !row.valueJson.isEmpty {
            descriptor.profile.overrides[String(row.key.dropFirst(5))] = row.valueJson
        }
        // Settings the player chose on the Runtime page win over hints and defaults.
        let ledger = ((try? store.overrides.all(game: record.id)) ?? []).map { (key: $0.key, value: $0.valueJson) }
        descriptor.profile.overrides.merge(RuntimeSettings.overrides(from: ledger)) { $1 }
        #if DEBUG
            // Ren'Py developer switches for this launch only, from `--renpy-switch developer,console`.
            for name in DebugLaunch.value(for: "--renpy-switch")?.split(separator: ",") ?? [] {
                descriptor.profile.overrides["renpy.\(name)"] = "1"
            }
        #endif
        // MIDI is the 2000/2003, XP and VX eras' music format, the RTPs' included, which live outside the game
        // folder where detection cannot see them; every RGSS and EasyRPG game gets the soundfont. FluidSynth loads
        // it on the first MIDI.
        let playsMIDI = switch resolution.selectedRuntime {
        case .rgss?, .easyrpg?: true
        default: false
        }
        if playsMIDI, let font = MIDISoundFont.installed(paths: paths) {
            descriptor.profile.overrides["midiSoundFont"] = font.path(percentEncoded: false)
        }
        return descriptor
    }
}
