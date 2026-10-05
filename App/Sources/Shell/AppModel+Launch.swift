import Diagnostics
import Foundation
import GameCore
import GameTools
import OverlayVFS
import RuntimeCore
import SaveKit

/// Save & Relaunch, recovery from a session that never tore down, and the debug-only launch switches: what
/// happens around a process start rather than inside one.
extension AppModel {
    /// Closes the session records of sessions that ended without teardown and names their games once. Their logs
    /// stay, marked by the tombstone, and MetricKit's crash report attaches there when it arrives.
    func reportUnfinishedSessions() {
        var titles: [String] = []
        for leftover in SessionMarker.consumeLeftovers(logsRoot: paths.logsRoot()) {
            OPLog.log(
                .crash,
                .error,
                "previous session ended without teardown: \(paths.stored(leftover.directory))",
                session: HostSession.shared.sessionID
            )
            if let id = leftover.session, let record = try? store?.sessions.fetch(id: id), record.teardownVerdict == nil {
                try? store?.sessions.end(
                    id: id,
                    verdict: "endedUnexpectedly",
                    grade: nil,
                    peakFootprint: nil,
                    notes: "no teardown; found at the next launch"
                )
            }
            if let game = leftover.game, let title = try? store?.games.fetch(id: game)?.title {
                titles.append(title)
            }
            if let report = CrashGuard.lastReport(in: leftover.directory) {
                lastCrash = report.what
            }
        }
        // A crash outside any game leaves its report with the host log of the launch it ended.
        if titles.isEmpty, let report = previousHostCrash() {
            lastCrash = report
        }
        #if DEBUG
            // Scripted launches open a game straight away; the alert would take the player screen down with it.
            if DebugLaunch.openFirstGame {
                return
            }
        #endif
        unexpectedEnds = titles
    }

    /// The cause of a crash that closed OmniPlay outside a game in an earlier launch, reported once.
    private func previousHostCrash() -> String? {
        let fm = FileManager.default
        let hostLogs = paths.logs(game: nil, session: HostSession.shared.sessionID.rawValue).deletingLastPathComponent()
        let launches = (try? fm.contentsOfDirectory(at: hostLogs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var newest: (date: Date, what: String)?
        for launch in launches where launch != HostSession.shared.directory {
            let seen = launch.appending(path: ".crash-reported")
            guard !fm.fileExists(atPath: seen.path(percentEncoded: false)),
                  let report = CrashGuard.lastReport(in: launch) else { continue }
            fm.createFile(atPath: seen.path(percentEncoded: false), contents: nil)
            let date = (try? launch.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if report.closedApp, date > newest?.date ?? .distantPast {
                newest = (date, report.what)
                // Export diagnostics bundles this launch's folder; the report travels with it.
                let copy = HostSession.shared.directory.appending(path: "previous-crash.txt")
                try? fm.removeItem(at: copy)
                try? fm.copyItem(at: launch.appending(path: CrashGuard.reportName), to: copy)
            }
        }
        return newest?.what
    }

    nonisolated static func relaunchFile(_ paths: AppPaths) -> URL { paths.exportsRoot.deletingLastPathComponent()
        .appending(path: "relaunch.json")
    }

    /// Save & Relaunch: saves are already flushed by the stop; the target is written for the next launch and the
    /// process exits. A personal app may do this; the confirmation dialog says so.
    func relaunch(opening id: GameID) async {
        await stopPlaying(reason: .hostShutdown)
        // Never force-quit under a Save & Relaunch promise when persistence was not confirmed.
        guard saveWarning == nil else { runtimeFailure = saveWarning; return }
        let url = Self.relaunchFile(paths)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(["game": id.description]).write(to: url, options: .atomic)
        OPLog.log(.runtime, .info, "relaunching to \(id)")
        try? await Task.sleep(for: .milliseconds(200))
        // The host sink buffers for a second; exit would drop the line above.
        await OPLog.defaultSession.flatMap(OPLog.sink(for:))?.flush()
        exit(0)
    }

    #if DEBUG
        func debugFaultIfRequested() {
            // Containment checks. `--debug-crash-in-game <seconds>[:kind]`: `host` (default) traps in a main-actor task,
            // which ends the app and leaves its report; `engine` faults inside the engine's run loop, `hang` spins
            // there, and `thread` faults on a thread of its own, all three of which the crash guard must survive.
            if let request = DebugLaunch.value(for: "--debug-crash-in-game") {
                let parts = request.split(separator: ":")
                let delay = parts.first.flatMap { Double($0) } ?? 5
                let kind = parts.count > 1 ? String(parts[1]) : "host"
                Task {
                    try? await Task.sleep(for: .seconds(delay))
                    OPLog.log(.crash, .info, "debug fault requested: \(kind)")
                    switch kind {
                    case "engine": RunLoop.main.perform { UnsafeMutablePointer<Int>(bitPattern: 8)!.pointee = 1 }
                    case "hang": RunLoop.main.perform { while true {} }
                    case "thread": // a raw pthread, as engines start them (Foundation's Thread carries a GCD label)
                        var thread: pthread_t?
                        pthread_create(&thread, nil, debugFaultOnThread, nil)
                    default: fatalError("crash requested by --debug-crash-in-game")
                    }
                }
            }
        }

        /// UI tests start from nothing: library database, game trees, saves and logs are removed before the store opens.
        nonisolated static func resetLibrary(paths: AppPaths) {
            let fm = FileManager.default
            // Sealed Original trees are read-only; without this the game folders survive the reset.
            for game in (try? fm.contentsOfDirectory(at: paths.games(), includingPropertiesForKeys: nil)) ?? [] {
                try? OriginalGuard.unseal(originalRoot: game.appending(path: "Original", directoryHint: .isDirectory))
            }
            for dir in [
                paths.games(),
                paths.logsRoot(),
                paths.database().deletingLastPathComponent(),
                paths.rescuedSaves(),
                paths.cachesRoot,
            ] {
                try? fm.removeItem(at: dir)
            }
            try? paths.ensureLayout()
        }
    #endif

    nonisolated static func consumeRelaunchRequest(paths: AppPaths) -> GameID? {
        let url = relaunchFile(paths)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url), let dict = try? JSONDecoder().decode([String: String].self, from: data),
              let raw = dict["game"] else { return nil }
        return GameID(uuidString: raw)
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
        /// Seconds after start to run the state probe (`AppModel.probeState`), from `--probe-state <seconds>`.
        static var probeStateDelay: Int? { value(for: "--probe-state").flatMap(Int.init) }
    }

    extension AppModel {
        /// Debug-only: exercises the running game's state bridge and logs each step (scripted simulator runs).
        func probeState() async {
            guard let inspector = await coordinator?.stateInspector else {
                OPLog.log(.runtime, .info, "STATEPROBE no state bridge for this runtime")
                return
            }
            // Ren'Py speaks in stores, persistent data and labels; the others in RPG Maker's categories.
            if let store = try? await inspector.inspect(.list(category: .store, query: nil, page: StatePage(size: 10))) {
                await probeRenPyState(inspector, store: store)
                return
            }
            do {
                let page = try await inspector.inspect(.list(category: .variables, query: nil, page: StatePage(size: 5)))
                OPLog.log(.runtime, .info, "STATEPROBE variables: \(page.entries.map { "\($0.name)=\($0.value)" }) more=\(page.hasMore)")
                let items = try await inspector.inspect(.list(category: .items, query: nil, page: StatePage(size: 3)))
                OPLog.log(.runtime, .info, "STATEPROBE items: \(items.entries.map { "\($0.name)=\($0.value)" })")
            } catch {
                OPLog.log(.runtime, .info, "STATEPROBE list failed: \(error)")
            }
            for mutation in [
                StateMutation(target: .variable(1), requested: .int(42)),
                StateMutation(target: .gold, requested: .int(12345)),
            ] {
                let result = await inspector.mutate(mutation)
                OPLog.log(
                    .runtime,
                    .info,
                    """
                    STATEPROBE set \(mutation.target): \(result.result) old=\(result.oldValue) \
                    now=\(result.effectiveValue) \(result.validation.map(\.message))
                    """
                )
            }
            if let read = try? await inspector.inspect(.get(.variable(1))) {
                OPLog.log(.runtime, .info, "STATEPROBE read back variable 1 = \(read.entries.first?.value ?? .null)")
            }
            await probeCheats()
            await probeTools([
                (.increment(by: 8), .variable(1)),
                (.setValue(.int(-5)), .gold),
                (.insertItem(count: 3), .item(kind: .item, id: 1)),
                (.setValue(.int(999_999_999)), .gold),
                (.setQuantity(150), .item(kind: .item, id: 2)),
            ])
        }

        private func probeRenPyState(_ inspector: any StateInspecting, store: StateInspectionResult) async {
            OPLog.log(
                .runtime,
                .info,
                "STATEPROBE store: \(store.entries.map { "\($0.name)=\($0.value)\($0.editable ? "" : " ro")" }) more=\(store.hasMore)"
            )
            for category in [StateCategory.persistent, .labels] {
                let page = try? await inspector.inspect(.list(category: category, query: nil, page: StatePage(size: 5)))
                OPLog.log(.runtime, .info, "STATEPROBE \(category): \(page?.entries.map { "\($0.name)=\($0.value)" } ?? ["failed"])")
            }
            let mutations = [
                StateMutation(target: .renpyStore(name: "store", path: ["score"]), requested: .int(42)),
                StateMutation(target: .renpyStore(name: "store", path: ["flags", "count"]), operation: .add, requested: .int(5)),
                StateMutation(target: .renpyStore(name: "store.quest", path: ["stage"]), requested: .int(3)),
                StateMutation(target: .renpyStore(name: "store", path: ["satchel"]), requested: .int(1)),
                StateMutation(target: .renpyPersistent(path: ["clears"]), requested: .int(99)),
            ]
            for mutation in mutations {
                let result = await inspector.mutate(mutation)
                OPLog.log(
                    .runtime,
                    .info,
                    """
                    STATEPROBE set \(mutation.target): \(result.result) old=\(result.oldValue) \
                    now=\(result.effectiveValue) persistent=\(result.persistent) \(result.validation.map(\.message))
                    """
                )
            }
            if let read = try? await inspector.inspect(.get(.renpyStore(name: "store", path: ["score"]))) {
                OPLog.log(.runtime, .info, "STATEPROBE read back score = \(read.entries.first?.value ?? .null)")
            }
            if let console = tools?.console {
                for (code, execute) in [
                    ("score", false),
                    ("score = 77", true),
                    ("score * 2", false),
                    ("1/0", false),
                    ("(config.console, config.hard_rollback_limit, config.rollback_enabled)", false),
                    ("renpy.has_label('omniplay_mod_loop')", false),
                    ("omniplay_insert_value", false),
                ] + (DebugLaunch.value(for: "--probe-eval").map { [($0, false)] } ?? []) {
                    let result = try? await console.runScript(code, execute: execute)
                    OPLog.log(
                        .runtime,
                        .info,
                        "STATEPROBE console \(execute ? "exec" : "eval") \(code): ok=\(result?.ok ?? false) \(result?.output ?? "failed")"
                    )
                }
                // A real save, then what the Save Manager reads back from it.
                let saved = try? await console.runScript("renpy.take_screenshot()\nrenpy.save('1-1', 'OmniPlay probe save')", execute: true)
                if let id = playing?.id {
                    let location = SaveLocation.forGame(id, paths: paths)
                    for (name, preview) in SavePreviewReader.previews(in: location.slots) {
                        OPLog.log(
                            .runtime,
                            .info,
                            """
                            STATEPROBE preview \(name): title=\(preview.title ?? "-") \
                            saved=\(preview.savedAt.map { "\($0)" } ?? "-") playtime=\(preview.playtime ?? "-") \
                            thumbnail=\(preview.thumbnail?.count ?? 0) bytes (save ok=\(saved?.ok ?? false) \
                            \(saved?.output ?? ""))
                            """
                        )
                    }
                    let files = Set(SaveSlotFile.list(in: location.slots).map(\.id))
                    OPLog.log(
                        .runtime,
                        .info,
                        """
                        STATEPROBE duplicate name for 1-1-LT1.save: \
                        \(SlotNaming.duplicateName(for: "1-1-LT1.save", existing: files, pattern: "%d-LT1.save") ?? "-")
                        """
                    )
                }
            }
            await probeTools([
                (.increment(by: 1), .renpyStore(name: "store", path: ["score"])),
                (.setValue(.string("lots")), .renpyStore(name: "store", path: ["score"])),
                (.toggle, .renpyStore(name: "store", path: ["met_eileen"])),
                (.setValue(.int(5)), .renpyPersistent(path: ["clears"])),
                (.setValue(.int(100)), .gold),
            ])
        }

        /// Every catalog cheat this engine offers: applied, then undone (the debug menu last, since it changes scene).
        private func probeCheats() async {
            guard let tools else { return }
            let cheats = CheatCatalog.bundled.available(for: tools.capabilities).sorted { a, _ in a.id != "system.debugMenu" }
            OPLog.log(.runtime, .info, "STATEPROBE cheats available: \(cheats.map(\.id))")
            for cheat in cheats {
                var values: [String: Int] = [:]
                for parameter in cheat.parameters {
                    values[parameter.key] = parameter.kind == .amount ? (parameter.defaultValue ?? 1) : 1
                }
                let outcome = await CheatRunner.run(cheat, parameters: values, with: tools)
                let summary = outcome.results.map { "\($0.target): \($0.result.rawValue) \($0.oldValue)→\($0.effectiveValue)" }
                await CheatRunner.undo(outcome, with: tools)
                OPLog.log(
                    .runtime,
                    .info,
                    """
                    STATEPROBE cheat \(cheat.id): applied=\(outcome.applied) recorded=\(outcome.recorded) \(summary) \
                    \(outcome.message ?? "")
                    """
                )
            }
        }

        /// The Game Tools path (MutationEngine): validation, the backup before a persistent change, and undo.
        private func probeTools(_ steps: [(ToolOperation, StateTarget)]) async {
            guard let tools else { return OPLog.log(.runtime, .info, "STATEPROBE no tools engine") }
            for (operation, target) in steps {
                let result = await tools.apply(operation, to: target)
                OPLog.log(
                    .runtime,
                    .info,
                    """
                    STATEPROBE tools \(operation) \(target): \(result.result) \(result.oldValue) → \
                    \(result.effectiveValue) persistent=\(result.persistent) \(result.validation.map(\.message))
                    """
                )
            }
            OPLog.log(.runtime, .info, "STATEPROBE tools records=\(tools.records.count)")
            // Freeze and watch: a write straight through the bridge stands in for the game changing the value.
            if let target = steps.first?.1 {
                let held = StateValue.int(10), other = StateValue.int(0)
                let inspector = tools.inspector
                tools.watch(target)
                let frozen = await tools.freeze(target, at: held)
                _ = await inspector.mutate(StateMutation(target: target, requested: other))
                try? await Task.sleep(for: .seconds(1))
                await tools.refreshWatches()
                let during = try? await inspector.inspect(.get(target)).entries.first?.value
                OPLog.log(
                    .runtime,
                    .info,
                    """
                    STATEPROBE freeze \(target): \(frozen.result) held=\(tools.frozen[target] ?? .null) after game \
                    write → \(during ?? .null) watched=\(tools.watched[target] ?? .null)
                    """
                )
                await tools.unfreeze(target)
                _ = await inspector.mutate(StateMutation(target: target, requested: other))
                try? await Task.sleep(for: .seconds(1))
                await tools.refreshWatches()
                let after = try? await inspector.inspect(.get(target)).entries.first?.value
                OPLog.log(
                    .runtime,
                    .info,
                    "STATEPROBE unfrozen \(target): after game write → \(after ?? .null) watched=\(tools.watched[target] ?? .null)"
                )
                tools.unwatch(target)
            }
            if let persistent = steps.first(where: {
                if case .renpyPersistent = $0.1 {
                    true
                } else {
                    false
                }
            }) {
                let result = await tools.freeze(persistent.1, at: .int(1))
                OPLog.log(.runtime, .info, "STATEPROBE freeze persistent: \(result.result) \(result.validation.map(\.message))")
            }
            while tools.canUndo {
                let result = await tools.undo()
                OPLog.log(
                    .runtime,
                    .info,
                    """
                    STATEPROBE tools undo \(result?.target as Any): \(result?.result.rawValue ?? "-") \
                    now=\(result?.effectiveValue ?? .null)
                    """
                )
            }
        }
    }
#endif
#if DEBUG
    /// Top level so it carries no actor isolation onto the thread it runs on.
    private func debugFaultOnThread(_: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
        UnsafeMutablePointer<Int>(bitPattern: 8)!.pointee = 1
        return nil
    }
#endif
