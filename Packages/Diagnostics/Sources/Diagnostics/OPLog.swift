import Foundation
import OSLog
import Synchronization

/// The one logging facility. Every line goes to OSLog; when a session is active it also goes to that
/// session's bounded `host.log` family so a diagnostics bundle can be exported without a Mac.
public enum OPLog {
    public static let subsystem = "com.omniplay.app"

    private static let sinks = Mutex<[SessionID: FileLogSink]>([:])
    private static let fallback = Mutex<SessionID?>(nil)

    /// Session used when a caller passes none, so package-level lines land in the host log too.
    public static var defaultSession: SessionID? {
        get { fallback.withLock { $0 } }
        set { fallback.withLock { $0 = newValue } }
    }

    private static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// `os_log_create` keeps its own cache, so a fresh value per call costs nothing extra.
    public static func logger(_ category: LogCategory) -> Logger { Logger(subsystem: subsystem, category: category.rawValue) }

    public static func log(_ category: LogCategory, _ level: OSLogType = .default, _ message: String, session: SessionID? = nil) {
        logger(category).log(level: level, "\(message, privacy: .public)")
        let resolved = sinks.withLock { sinks in session.flatMap { sinks[$0] } ?? defaultSession.flatMap { sinks[$0] } }
        guard let sink = resolved else { return }
        let line = "\(Date.now.formatted(timestamp))\t\(level.label)\t\(category.rawValue)\t\(message)"
        Task { await sink.append(line) }
    }

    /// Starts writing `host.log` under `directory` for `session`. Returns the sink so tests can flush it.
    @discardableResult
    public static func beginSession(_ session: SessionID, directory: URL) -> FileLogSink {
        let sink = FileLogSink(directory: directory)
        sinks.withLock { $0[session] = sink }
        return sink
    }

    public static func endSession(_ session: SessionID) async {
        guard let sink = sinks.withLock({ $0.removeValue(forKey: session) }) else { return }
        await sink.close()
    }

    public static func sink(for session: SessionID) -> FileLogSink? { sinks.withLock { $0[session] } }
}

extension OSLogType {
    var label: String {
        switch self {
        case .debug: "debug"
        case .info: "info"
        case .error: "error"
        case .fault: "fault"
        default: "default"
        }
    }
}
