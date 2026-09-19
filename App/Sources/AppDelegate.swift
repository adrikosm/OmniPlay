import Diagnostics
import GameCore
import UIKit

/// Process-level hooks SwiftUI does not expose: storage layout, the host session log and the memory
/// recorder start here. Later phases add crash reporting and controller discovery.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        HostSession.shared.start()
        return true
    }
}

/// The app-lifetime diagnostics session: `Logs/host/<session>/{host.log,memory.jsonl}`.
@MainActor
final class HostSession {
    static let shared = HostSession()

    let paths: AppPaths
    let sessionID = SessionID()
    private(set) var layoutError: Error?
    private var recorder: MemoryRecorder?
    private var pressureTask: Task<Void, Never>?

    var directory: URL { paths.logs(game: nil, session: sessionID.rawValue) }

    private init() {
        paths = (try? AppPaths.applicationDefault()) ?? AppPaths.temporary()
    }

    func start() {
        do { try paths.ensureLayout() } catch { layoutError = error }
        OPLog.beginSession(sessionID, directory: directory)
        OPLog.defaultSession = sessionID
        OPLog.log(.runtime, .info, "OmniPlay launched (UIScene lifecycle) session=\(sessionID)", session: sessionID)
        if let layoutError {
            OPLog.log(.filesystem, .fault, "storage layout failed: \(layoutError)", session: sessionID)
        }
        let recorder = MemoryRecorder(fileURL: directory.appending(path: "memory.jsonl"))
        self.recorder = recorder
        Task { await recorder.record(MemoryProbe.sample(label: "launch"), force: true) }
        pressureTask = Task {
            for await level in MemoryPressureMonitor.levels() {
                OPLog.log(.memory, .default, "memory pressure \(level.rawValue)", session: sessionID)
                await recorder.record(MemoryProbe.sample(label: "pressure", pressure: level), force: true)
            }
        }
    }

    func recordMemory(label: String) {
        guard let recorder else { return }
        Task { await recorder.record(MemoryProbe.sample(label: label), force: true) }
    }

    func exportBundle() throws -> URL {
        if let sink = OPLog.sink(for: sessionID) {
            Task { await sink.flush() }
        }
        return try DiagnosticsBundle.export(sessionDirectory: directory)
    }
}
