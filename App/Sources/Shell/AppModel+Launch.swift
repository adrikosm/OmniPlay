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
