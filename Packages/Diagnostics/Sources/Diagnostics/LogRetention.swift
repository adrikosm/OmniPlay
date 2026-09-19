import Foundation

/// Keeps `Logs/` bounded: newest sessions per game, pinned sessions (crash markers, exported bundles) a little
/// longer, and a total cap pruned oldest first. File sizes are bounded where they are written (`FileLogSink`,
/// `MemoryRecorder`); this only decides which session directories survive.
public enum LogRetention {
    public struct Policy: Sendable {
        public var sessionsPerGame = 10
        public var pinnedPerGame = 20
        public var totalBytes: Int64 = 512 << 20
        public init() {}
    }

    public struct Outcome: Sendable, Equatable {
        public var removedSessions = 0
        public var remainingBytes: Int64 = 0
    }

    /// A session is pinned while it holds a crash marker or was exported as a bundle.
    public static let pinMarkers = ["termination.json", "crash.json", ".exported"]

    struct Session {
        let url: URL
        let modified: Date
        let bytes: Int64
        let pinned: Bool
    }

    @discardableResult
    public static func sweep(logsRoot: URL, policy: Policy = Policy()) -> Outcome {
        let fm = FileManager.default
        var outcome = Outcome()
        guard let games = try? fm.contentsOfDirectory(at: logsRoot, includingPropertiesForKeys: [.isDirectoryKey]) else { return outcome }
        var survivors: [Session] = []
        for game in games where (try? game.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            var sessions = ((try? fm.contentsOfDirectory(at: game, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .map(describe)
                .sorted { $0.modified > $1.modified }
            var kept = 0, keptPinned = 0
            var remaining: [Session] = []
            for session in sessions {
                let keep = session.pinned ? keptPinned < policy.pinnedPerGame : kept < policy.sessionsPerGame
                if keep {
                    remaining.append(session)
                    if session.pinned {
                        keptPinned += 1
                    } else {
                        kept += 1
                    }
                } else if (try? fm.removeItem(at: session.url)) != nil {
                    outcome.removedSessions += 1
                }
            }
            sessions = remaining
            survivors += sessions
        }
        var total = survivors.reduce(0) { $0 + $1.bytes }
        for session in survivors.sorted(by: { $0.modified < $1.modified }) where total > policy.totalBytes {
            if (try? fm.removeItem(at: session.url)) != nil {
                total -= session.bytes
                outcome.removedSessions += 1
            }
        }
        outcome.remainingBytes = total
        if outcome.removedSessions > 0 {
            OPLog.log(.crash, .info, "log retention removed \(outcome.removedSessions) sessions")
        }
        return outcome
    }

    private static func describe(_ url: URL) -> Session {
        let fm = FileManager.default
        var bytes: Int64 = 0
        var modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        var pinned = false
        if let files = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let file as URL in files {
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                bytes += Int64(values?.fileSize ?? 0)
                if let date = values?.contentModificationDate, date > modified {
                    modified = date
                }
                if pinMarkers.contains(file.lastPathComponent) {
                    pinned = true
                }
            }
        }
        if fm.fileExists(atPath: url.appending(path: ".exported").path(percentEncoded: false)) {
            pinned = true
        }
        return Session(url: url, modified: modified, bytes: bytes, pinned: pinned)
    }
}
