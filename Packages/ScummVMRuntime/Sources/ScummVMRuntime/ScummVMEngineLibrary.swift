import Darwin
import Diagnostics
import Foundation
import GameCore
import GameDetection

/// The embedded ScummVM (`Frameworks/ScummVM.framework`), opened on first use.
///
/// Unlike the other native engines it starts once and stays: `op_scummvm_start` runs `scummvm_main` on its own thread,
/// and between games that thread waits for the host (OmniPlay's patch replaces ScummVM's launcher with that wait). So
/// the same process plays game after game, and detection runs on the waiting thread with ScummVM's own tables.
///
/// ScummVM's filesystem is chrooted to the app's home directory; `scummPath` turns a URL into the path it expects.
public final class ScummVMEngineLibrary: @unchecked Sendable {
    public enum Status: Int32, Sendable { case notStarted = 0, waiting, starting, playing, paused, exited }
    public enum Command: Int32, Sendable { case run = 0, pause, leave }

    public enum Failure: Error, CustomStringConvertible {
        case loadFailed(String)
        case symbolMissing(String)
        case notReady

        public var description: String {
            switch self {
            case let .loadFailed(reason): "ScummVM could not be loaded: \(reason)"
            case let .symbolMissing(name): "ScummVM is incomplete (\(name) missing)."
            case .notReady: "ScummVM did not get ready in time."
            }
        }
    }

    /// One candidate from ScummVM's detection.
    public struct Candidate: Decodable, Sendable, Equatable {
        public let engineid: String
        public let gameid: String
        public let description: String
        public let language: String
        public let platform: String
        public let extra: String
    }

    private struct API {
        let version: @convention(c) () -> UnsafePointer<CChar>?
        let start: @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
        let status: @convention(c) () -> Int32
        let detect: @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int32) -> Int32
        let play: @convention(c) (UnsafePointer<CChar>?) -> Int32
        let lastResult: @convention(c) (UnsafeMutablePointer<CChar>?, Int32) -> Int32
        let request: @convention(c) (Int32) -> Void
        let frames: @convention(c) () -> UInt
        let key: @convention(c) (Int32, Int32) -> Void
        let mainMenu: @convention(c) () -> Void
        let window: @convention(c) () -> UnsafeMutableRawPointer?
        let appEvent: @convention(c) (Int32) -> Void
        let log: @convention(c) (UnsafePointer<CChar>?) -> Void
    }

    public let binaryURL: URL
    private let lock = NSLock()
    private var loadedAPI: API?
    private var api: API? { lock.withLock { loadedAPI } }
    @MainActor public private(set) var bootInvoked = false
    private static let openedLock = NSLock()
    private nonisolated(unsafe) static var opened: ScummVMEngineLibrary?

    /// The framework when this build embeds it.
    public static func bundled(in bundle: Bundle = .main) -> ScummVMEngineLibrary? {
        openedLock.lock()
        defer { openedLock.unlock() }
        if let opened {
            return opened
        }
        guard let binary = bundle.privateFrameworksURL?.appending(path: "ScummVM.framework/ScummVM"),
              FileManager.default.fileExists(atPath: binary.path(percentEncoded: false)) else { return nil }
        let library = ScummVMEngineLibrary(binaryURL: binary)
        opened = library
        return library
    }

    private init(binaryURL: URL) {
        self.binaryURL = binaryURL
    }

    private func load() throws -> API {
        lock.lock()
        defer { lock.unlock() }
        if let api = loadedAPI {
            return api
        }
        guard let handle = dlopen(binaryURL.path(percentEncoded: false), RTLD_NOW | RTLD_LOCAL) else {
            throw Failure.loadFailed(dlerror().map { String(cString: $0) } ?? "unknown dlopen error")
        }
        func symbol<T>(_ name: String, as _: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else { throw Failure.symbolMissing(name) }
            return unsafeBitCast(pointer, to: T.self)
        }
        let api = try API(
            version: symbol("op_scummvm_version", as: (@convention(c) () -> UnsafePointer<CChar>?).self),
            start: symbol(
                "op_scummvm_start",
                as: (@convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32).self
            ),
            status: symbol("op_scummvm_status", as: (@convention(c) () -> Int32).self),
            detect: symbol(
                "op_scummvm_detect",
                as: (@convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int32) -> Int32).self
            ),
            play: symbol("op_scummvm_play", as: (@convention(c) (UnsafePointer<CChar>?) -> Int32).self),
            lastResult: symbol("op_scummvm_last_result", as: (@convention(c) (UnsafeMutablePointer<CChar>?, Int32) -> Int32).self),
            request: symbol("op_scummvm_request", as: (@convention(c) (Int32) -> Void).self),
            frames: symbol("op_scummvm_frames", as: (@convention(c) () -> UInt).self),
            key: symbol("op_scummvm_key", as: (@convention(c) (Int32, Int32) -> Void).self),
            mainMenu: symbol("op_scummvm_main_menu", as: (@convention(c) () -> Void).self),
            window: symbol("op_scummvm_window", as: (@convention(c) () -> UnsafeMutableRawPointer?).self),
            appEvent: symbol("op_scummvm_app_event", as: (@convention(c) (Int32) -> Void).self),
            log: symbol("op_scummvm_log", as: (@convention(c) (UnsafePointer<CChar>?) -> Void).self)
        )
        loadedAPI = api
        OPLog.log(.runtime, .info, "loaded ScummVM \(api.version().map { String(cString: $0) } ?? "?")")
        return api
    }

    public func reportedVersion() throws -> String {
        try load().version().map { String(cString: $0) } ?? "unknown"
    }

    /// The path ScummVM sees for `url`: relative to the app's home directory, with a leading slash; files in the
    /// app bundle go through the backend's `appbundle:` drive.
    public static func scummPath(_ url: URL) -> String {
        let home = URL(filePath: NSHomeDirectory()).resolvingSymlinksInPath().path(percentEncoded: false)
        var path = url.resolvingSymlinksInPath().path(percentEncoded: false)
        if let bundle = Bundle.main.resourceURL?.resolvingSymlinksInPath().path(percentEncoded: false), path.hasPrefix(bundle) {
            return "appbundle:/" + path.dropFirst(bundle.count).drop { $0 == "/" }
        }
        if path.hasPrefix(home) {
            path.removeFirst(home.count)
        }
        if path.hasSuffix("/"), path.count > 1 {
            path.removeLast()
        }
        return path.hasPrefix("/") ? path : "/" + path
    }

    /// Starts ScummVM's thread once per process (main thread only) and waits until it is ready for a game.
    /// `configFile` is ScummVM's own settings file, which the caller writes first.
    @MainActor
    public func startIfNeeded(configFile: URL) async throws {
        let api = try load()
        if Status(rawValue: api.status()) == .notStarted {
            // The shim copies argv for ScummVM; these copies live only for the call.
            var argv = ["scummvm", "-c", Self.scummPath(configFile)].map { strdup($0) } + [nil]
            _ = api.start(Int32(argv.count - 1), &argv)
            bootInvoked = true
            argv.forEach { free($0) }
            OPLog.log(.runtime, .info, "ScummVM started")
        }
        let deadline = ContinuousClock.now + .seconds(30)
        while status == .notStarted, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard status != .notStarted, status != .exited else { throw Failure.notReady }
    }

    public var isStarted: Bool { api.map { Status(rawValue: $0.status()) != .notStarted } ?? false }
    public var status: Status { api.flatMap { Status(rawValue: $0.status()) } ?? .notStarted }
    public var frames: UInt { api?.frames() ?? 0 }

    /// ScummVM's detection over a folder; blocks until ScummVM's thread answers, so never call it on the main thread.
    /// Empty when nothing is recognised; nil when ScummVM cannot answer now (not waiting between games).
    public func detect(_ folder: URL) -> [Candidate]? {
        guard let api, !Thread.isMainThread else { return nil }
        var out = [CChar](repeating: 0, count: 64 << 10)
        let count = api.detect(Self.scummPath(folder), &out, Int32(out.count))
        guard count >= 0 else { return nil }
        guard count > 0, let data = String(cString: out).data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Candidate].self, from: data)) ?? []
    }

    /// Hands ScummVM the next game as `key=value` settings for its config domain. False unless it was waiting.
    public func play(_ settings: [String: String]) -> Bool {
        let text = settings.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        return api?.play(text) == 1
    }

    /// The last game's outcome: 0 for a normal end, otherwise ScummVM's error code and message.
    public func lastResult() -> (code: Int32, message: String) {
        guard let api else { return (0, "") }
        var out = [CChar](repeating: 0, count: 1024)
        let code = api.lastResult(&out, Int32(out.count))
        return (code, String(cString: out))
    }

    public func request(_ command: Command) { api?.request(command.rawValue) }
    /// Where ScummVM's own messages go from now on (the session's log folder).
    public func setLog(_ file: URL) throws { try load().log(file.path(percentEncoded: false)) }
    /// A ScummVM keycode (`Common::KeyCode`).
    public func key(_ keycode: Int32) { api?.key(keycode, keycode) }
    public func openMainMenu() { api?.mainMenu() }
    public func window() -> UnsafeMutableRawPointer? { api?.window() }
    /// 0 will resign active, 1 did enter background, 2 will enter foreground, 3 did become active.
    public func appEvent(_ event: Int32) { api?.appEvent(event) }
}

public extension ScummVMEngineLibrary {
    /// ScummVM's settings file: the global section only; each game gets its own domain from `play`. Rewritten on
    /// every start so a changed default reaches existing installs. The data folder is the framework's own.
    static func writeConfig(to file: URL, muted: Bool) throws {
        let data = "appbundle:/Frameworks/ScummVM.framework/data"
        var lines = [
            "[scummvm]",
            // After a game ends ScummVM goes back to its launcher, which OmniPlay's patch turns into waiting for the host.
            "gui_return_to_launcher_at_exit=true",
            "enable_unsupported_game_warning=false",
            "confirm_exit=false",
            "extrapath=\(data)",
            "themepath=\(data)",
            "gui_theme=scummremastered",
            // ScummVM's own on-screen gamepad would register as a controller with OmniPlay's input layer too.
            "gamepad_controller=false",
        ]
        if muted {
            lines.append("mute=true")
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file, options: .atomic)
    }

    /// Installs ScummVM's detection as the authority for `ScummVMDetector`. Detection runs on ScummVM's waiting
    /// thread, so the first call starts ScummVM (on the main thread) when nothing has yet.
    static func installDetection(configFile: URL, muted: Bool) {
        ScummVMDetector.identify = { folder in
            guard !Thread.isMainThread else { return .unavailable }
            guard let library = ScummVMEngineLibrary.bundled() else { return .unavailable }
            if !library.isStarted {
                let semaphore = DispatchSemaphore(value: 0)
                Task { @MainActor in
                    try? writeConfig(to: configFile, muted: muted)
                    try? await library.startIfNeeded(configFile: configFile)
                    semaphore.signal()
                }
                guard semaphore.wait(timeout: .now() + 40) == .success else { return .unavailable }
            }
            // A game running now means no answer rather than a wait: the signatures stand in.
            guard let candidates = library.detect(folder) else { return .unavailable }
            guard let best = candidates.first else { return .unrecognised }
            return .recognised(ScummVMDetector.Identity(
                engineID: best.engineid,
                gameID: best.gameid,
                title: best.description,
                language: best.language,
                platform: best.platform
            ))
        }
    }
}
