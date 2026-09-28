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

    /// 2...9 makes the engine's own frame limiter pace faster; 1 is off. Runtimes that cannot are a no-op.
    func setFastForward(_ multiplier: Int) async { await coordinator?.setFastForward(multiplier) }

    var engineMenuTitle: String? {
        get async { await coordinator?.engineMenuTitle }
    }

    func openEngineMenu() async { await coordinator?.openEngineMenu() }

    func captureScreen() async -> CGImage? { await coordinator?.captureScreen() }

    var speedChoices: SpeedChoices? {
        get async { await coordinator?.speedChoices }
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

    /// The stored detection report and resolution for a game, read off the main actor.
    nonisolated static func snapshot(for id: GameID, paths: AppPaths) -> DetectionSnapshot? {
        let url = paths.logs(game: id, session: UUID()).deletingLastPathComponent().appending(path: "detection.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DetectionSnapshot.self, from: data)
    }

    /// Re-resolves a stored report against the runtimes this build actually has (a game imported before
    /// a runtime landed keeps its report; only the choice is refreshed).
    func freshResolution(for record: GameRecord, snapshot: DetectionSnapshot) async -> RuntimeResolution {
        await RuntimeResolver(registry: registry).resolve(
            snapshot.report,
            override: pendingFallback[record.id] ?? record.manualRuntimeOverride
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
