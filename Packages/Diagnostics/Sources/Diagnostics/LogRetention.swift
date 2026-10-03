import Foundation

/// Keeps `Logs/` bounded: newest sessions per game, pinned sessions (crash markers, exported bundles) a little
/// longer, and a total cap pruned oldest first. File sizes are bounded where they are written (`FileLogSink`,
/// `MemoryRecorder`); this only decides which session directories survive.
public enum LogRetention {
    static let sessionsPerGame = 10
    static let pinnedPerGame = 20
    static let totalBytes: Int64 = 512 << 20

    /// A session is pinned while it holds a crash marker or was exported as a bundle. `.ended-unexpectedly` is the
    /// tombstone `SessionMarker` leaves on a session that never tore down (RuntimeCore names it; this package cannot).
    public static let pinMarkers = ["termination.json", "crash.json", ".exported", ".ended-unexpectedly"]

    struct Session {
        let url: URL
        let modified: Date
        let bytes: Int64
        let pinned: Bool
    }

    public static func sweep(logsRoot: URL) {
        let fm = FileManager.default
        guard let games = try? fm.contentsOfDirectory(at: logsRoot, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        var removed = 0
        var survivors: [Session] = []
        for game in games where (try? game.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let sessions = ((try? fm.contentsOfDirectory(at: game, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .map(describe)
                .sorted { $0.modified > $1.modified }
            var kept = 0, keptPinned = 0
            for session in sessions {
                let keep = session.pinned ? keptPinned < pinnedPerGame : kept < sessionsPerGame
                if keep {
                    survivors.append(session)
                    if session.pinned {
                        keptPinned += 1
                    } else {
                        kept += 1
                    }
                } else if (try? fm.removeItem(at: session.url)) != nil {
                    removed += 1
                }
            }
        }
        var total = survivors.reduce(0) { $0 + $1.bytes }
        for session in survivors.sorted(by: { $0.modified < $1.modified }) where total > totalBytes {
            if (try? fm.removeItem(at: session.url)) != nil {
                total -= session.bytes
                removed += 1
            }
        }
        if removed > 0 {
            OPLog.log(.crash, .info, "log retention removed \(removed) sessions")
        }
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
        // The enumerator skips hidden files, so the dot-named markers are looked up directly.
        if pinMarkers.contains(where: { $0.hasPrefix(".") && fm.fileExists(atPath: url.appending(path: $0).path(percentEncoded: false)) }) {
            pinned = true
        }
        return Session(url: url, modified: modified, bytes: bytes, pinned: pinned)
    }
}
