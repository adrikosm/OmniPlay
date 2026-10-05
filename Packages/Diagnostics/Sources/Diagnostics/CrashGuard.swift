import CCrashGuard
import Darwin
import Foundation

/// The Swift face of `crash_guard.c`. Every crash, and every hang an engine is pulled out of, leaves a `crash.txt`
/// in the running session's log folder (the host's outside a game): what happened, on which thread, in which engine,
/// the stack, the last log lines and the tail of stderr. Where the app can survive it, it does: a native engine's
/// main loop runs under `run(engine:_:)`, and a crash on an engine's own thread stops only that thread.
public enum CrashGuard {
    /// Engine statuses below this mean "abandoned after signal `statusBase - status`".
    public static let statusBase: Int32 = -1000
    public static let reportName = "crash.txt"
    static let stderrCap: off_t = 8 << 20

    private nonisolated(unsafe) static var hostDirectory: URL?
    @MainActor private static var source: DispatchSourceRead?
    @MainActor private static var stderrTrim: Timer?

    /// Called on the main actor with an engine status when a thread crashed and was stopped instead of the app.
    @MainActor public static var onThreadCrash: ((Int32) -> Void)?

    /// Installs the handlers and reports into `directory` until a game session moves them. When nothing reads stderr
    /// (a home-screen launch, a scripted simulator run) stdout and stderr go to `stderr.log` there, so engine messages
    /// written there (Ruby's bug report, an uncaught C++ exception) are kept.
    @MainActor
    public static func install(directory: URL) {
        hostDirectory = directory
        op_crash_install()
        setDirectory(directory)
        captureStandardOutput(in: directory)
        NSSetUncaughtExceptionHandler { exception in
            op_crash_note("uncaught exception \(exception.name.rawValue): \(exception.reason ?? "no reason given")")
        }
        listen()
    }

    /// The game session's log folder while it runs; nil goes back to the host's.
    public static func setDirectory(_ url: URL?) {
        guard let url = url ?? hostDirectory else { return }
        op_crash_set_directory(url.path(percentEncoded: false))
    }

    /// Runs an engine's main loop on the main thread under a recovery point. Returns the engine's own status, or a
    /// status `describe(status:)` explains when the engine crashed or hung and was left behind.
    public static func run(engine: String, _ body: () -> Int32) -> Int32 {
        engine.withCString { name in op_crash_engine_call(name) { body() } }
    }

    /// Keeps a log line for the next crash report.
    static func note(_ line: String) { op_crash_note(line) }

    /// The one-line cause of the first crash or hang in this session (or launch, outside one); empty before any.
    public static var lastSummary: String { String(cString: op_crash_last_summary()) }

    /// The player-facing message for a status from `run` or `onThreadCrash`; nil for an engine's ordinary end.
    public static func describe(status: Int32) -> String? {
        let signal = statusBase - status
        guard signal > 0, signal < 64 else { return nil }
        let what = signal == SIGEMT ? "The game stopped responding" : "The game crashed"
        return "\(what), so OmniPlay closed it and kept running. To play a game on this engine again, restart OmniPlay. "
            + "Diagnostics has the crash report.\(lastSummary.isEmpty ? "" : "\n\n\(lastSummary)")"
    }

    /// The newest report in `directory`: its cause and whether it ended the app.
    public static func lastReport(in directory: URL) -> (what: String, closedApp: Bool)? {
        let url = directory.appending(path: reportName)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65536 ? size - 65536 : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        let lines = (String(bytes: data, encoding: .utf8) ?? "").split(separator: "\n")
        guard let what = lines.last(where: { $0.hasPrefix("what: ") }) else { return nil }
        let outcome = lines.last { $0.hasPrefix("outcome: ") }
        return (String(what.dropFirst(6)), outcome == "outcome: OmniPlay closed")
    }

    @MainActor
    private static func listen() {
        let fd = op_crash_notify_fd()
        guard fd >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler {
            var byte: UInt8 = 0
            guard read(fd, &byte, 1) == 1 else { return }
            MainActor.assumeIsolated {
                OPLog.log(.crash, .fault, "a thread crashed and was stopped: \(lastSummary)")
                onThreadCrash?(statusBase - Int32(byte))
            }
        }
        source.resume()
        self.source = source
    }

    @MainActor
    private static func captureStandardOutput(in directory: URL) {
        guard isatty(STDERR_FILENO) == 0 else { return } // Xcode's console is reading it
        let path = directory.appending(path: "stderr.log").path(percentEncoded: false)
        let fd = open(path, O_RDWR | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        dup2(fd, STDOUT_FILENO)
        dup2(fd, STDERR_FILENO)
        setvbuf(stdout, nil, _IOLBF, 0)
        op_crash_set_stderr_fd(fd)
        // Engines can be chatty; the log restarts rather than grow past the cap.
        stderrTrim = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            if lseek(fd, 0, SEEK_END) > stderrCap {
                ftruncate(fd, 0)
            }
        }
    }
}
