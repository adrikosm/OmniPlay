import OSLog

/// Factory for per-category loggers. No telemetry, no network: OSLog only, exported on demand
/// as a per-session bundle (host.log, detection.json, runtime.log, memory.jsonl, termination.json).
public enum DiagnosticsLog {
    public static let subsystem = "com.adrikosm.omniplay"

    public static func logger(_ category: LogCategory) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }
}
