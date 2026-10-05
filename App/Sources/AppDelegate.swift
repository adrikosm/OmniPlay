import Diagnostics
import GameCore
import MetricKit
import RuntimeCore
import UIKit

/// Process-level hooks SwiftUI does not expose: storage layout, the host session log and the memory
/// recorder start here. Later phases add crash reporting and controller discovery.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        HostSession.shared.start()
        #if DEBUG
            // Scripted test runs: every engine plays silently. Each engine reads its own switch when it starts:
            // SDL (EasyRPG, Ren'Py) a dummy audio driver, OpenAL (mkxp-z) its null backend, WebKit a page script.
            if CommandLine.arguments.contains("--mute-audio") {
                setenv("SDL_AUDIODRIVER", "dummy", 1)
                setenv("ALSOFT_DRIVERS", "null", 1)
                setenv("OMNIPLAY_MUTE", "1", 1)
                OPLog.log(.runtime, .info, "all game audio muted for this run (--mute-audio)")
            }
        #endif
        return true
    }

    func application(_: UIApplication, supportedInterfaceOrientationsFor _: UIWindow?) -> UIInterfaceOrientationMask {
        RuntimeHostViewController.sceneOrientations
    }

    /// Godot 3 and 4 read `UIApplication.shared.delegate.window` on every frame of a device with motion sensors (to
    /// turn the accelerometer with the screen). A delegate without `window` raised "unrecognized selector" there and
    /// took the whole app down on the phone; the simulator has no motion sensors, so it never showed. The scene owns
    /// the windows; this answers with the app's own.
    var window: UIWindow? {
        get {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            return scene?.keyWindow ?? scene?.windows.first
        }
        set { _ = newValue } // UIKit never assigns it under the scene lifecycle; nothing to keep
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
    private var crashReports: CrashReports?
    private var pressureTask: Task<Void, Never>?

    var directory: URL { paths.logs(game: nil, session: sessionID.rawValue) }

    private init() {
        paths = (try? AppPaths.applicationDefault()) ?? AppPaths.temporary()
    }

    func start() {
        do { try paths.ensureLayout() } catch { layoutError = error }
        OPLog.beginSession(sessionID, directory: directory)
        OPLog.defaultSession = sessionID
        CrashGuard.install(directory: directory)
        OPLog.log(.runtime, .info, "OmniPlay launched (UIScene lifecycle) session=\(sessionID)", session: sessionID)
        if let layoutError {
            OPLog.log(.filesystem, .fault, "storage layout failed: \(layoutError)", session: sessionID)
        }
        let reports = CrashReports(logsRoot: paths.logsRoot(), fallback: directory)
        MXMetricManager.shared.add(reports)
        crashReports = reports
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

    func exportBundle() async throws -> URL { try await SessionBundle.export(sessionDirectory: directory) }
}
