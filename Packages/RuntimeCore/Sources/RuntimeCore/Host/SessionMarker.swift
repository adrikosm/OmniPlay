import Foundation
import GameCore

/// A file that exists only while a session is running. The coordinator writes it before the runtime prepares and
/// removes it once teardown has run, whatever the verdict. If it is still there at the next launch, the previous
/// session ended without teardown: a crash, a kill from the app switcher, a hang the player escaped by quitting
/// OmniPlay. `consumeLeftovers` then turns it into a tombstone that stays with the session's logs, where crash
/// reports attach and the session bundle picks it up.
public struct SessionMarker: Sendable {
    public static let fileName = ".session-active"
    public static let tombstoneName = ".ended-unexpectedly"
    public let directory: URL

    /// One session that ended without teardown. The directory is `Logs/<game>/<session>/`.
    public struct Leftover: Sendable {
        public let directory: URL
        public var session: UUID? { UUID(uuidString: directory.lastPathComponent) }
        public var game: GameID? { GameID(uuidString: directory.deletingLastPathComponent().lastPathComponent) }
    }

    public init(directory: URL) { self.directory = directory }

    private var url: URL { directory.appending(path: Self.fileName) }

    public func write(game: GameID, runtime: String) {
        let body = ["game": game.description, "runtime": runtime, "startedAt": ISO8601DateFormatter().string(from: .now)]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(body).write(to: url, options: .atomic)
    }

    public func clear() { try? FileManager.default.removeItem(at: url) }

    /// Every session directory under `Logs/` that still carries a marker, each marker renamed to the tombstone so
    /// it is reported once.
    public static func consumeLeftovers(logsRoot: URL) -> [Leftover] {
        sessionDirectories(logsRoot: logsRoot, containing: fileName).map { dir in
            let fm = FileManager.default
            let tombstone = dir.appending(path: tombstoneName)
            try? fm.removeItem(at: tombstone)
            try? fm.moveItem(at: dir.appending(path: fileName), to: tombstone)
            return Leftover(directory: dir)
        }
    }

    /// The session that most recently ended without teardown, by when its tombstone was written.
    public static func newestTombstone(logsRoot: URL) -> URL? {
        sessionDirectories(logsRoot: logsRoot, containing: tombstoneName).max { a, b in
            modified(a.appending(path: tombstoneName)) < modified(b.appending(path: tombstoneName))
        }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func sessionDirectories(logsRoot: URL, containing name: String) -> [URL] {
        let fm = FileManager.default
        let games = (try? fm.contentsOfDirectory(at: logsRoot, includingPropertiesForKeys: nil)) ?? []
        return games.flatMap { game in
            ((try? fm.contentsOfDirectory(at: game, includingPropertiesForKeys: nil)) ?? [])
                .filter { fm.fileExists(atPath: $0.appending(path: name).path(percentEncoded: false)) }
        }
    }
}
