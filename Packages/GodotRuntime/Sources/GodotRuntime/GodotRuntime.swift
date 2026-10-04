#if canImport(UIKit)
    import Diagnostics
    import Foundation
    import GameCore
    import InputKit
    import OverlayVFS
    import RuntimeCore
    import SaveKit
    import UIKit

    /// Imported Godot 4 games (their exported `.pck`) through the embedded Godot engine.
    ///
    /// Godot runs the pack with `--main-pack`; `user://`, where Godot games keep saves and settings, is the game's
    /// `Saves/slots` (stock iOS Godot would use Documents). Godot's view controller sits in a window of its own that the
    /// host places in its scene. Godot reads touches, controllers and keyboards itself, so host input is ignored. One
    /// game per process: every stop is `.slotSpent`.
    @MainActor
    public final class GodotRuntime: GameRuntime {
        public enum Failure: Error, CustomStringConvertible {
            case notPrepared
            case engineMissing
            case packMissing
            case noFrames

            public var description: String {
                switch self {
                case .notPrepared: "The session was not prepared."
                case .engineMissing: "This build has no Godot engine."
                case .packMissing: "The game's .pck file is missing."
                case .noFrames: "Godot did not draw the game; see the session log."
                }
            }
        }

        private let bucket: GodotBucket
        private var configuration: RuntimeConfiguration?
        private var library: GodotEngineLibrary?
        private var arguments: [String] = []
        private weak var host: (any RuntimeHost)?
        private var window: UIWindow?
        private var observers: [NSObjectProtocol] = []

        public init(bucket: GodotBucket) {
            self.bucket = bucket
        }

        public func prepare(configuration: RuntimeConfiguration) async throws {
            guard let library = GodotEngineLibrary.bundled(bucket == .v36 ? .godot3 : .godot4) else { throw Failure.engineMissing }
            guard library.isAvailable else { throw GodotEngineLibrary.Failure.alreadySpent }
            self.configuration = configuration
            self.library = library
            let game = configuration.originalRoot
            guard let entry = configuration.entryPoint,
                  FileManager.default.fileExists(atPath: game.appending(path: entry).path(percentEncoded: false))
            else { throw Failure.packMissing }
            try configuration.ensureSessionDirectories()

            arguments = [
                "--main-pack", game.appending(path: entry).path(percentEncoded: false),
            ]
            // Godot 3 has no --log-file.
            if bucket != .v36 {
                arguments += ["--log-file", configuration.logDirectory.appending(path: "godot.log").path(percentEncoded: false)]
            }
            // Godot 4's simulator build has only its OpenGL ES 3 (compatibility) renderer: Godot's Metal driver refuses
            // the simulator's GPU. On the phone Metal is the default unless the player chose Compatibility.
            #if targetEnvironment(simulator)
                let opengl = true
            #else
                let opengl = configuration.profile.overrides["renderer"] == "opengl3"
            #endif
            if bucket != .v36, opengl {
                arguments += ["--rendering-driver", "opengl3"]
            }
            if ProcessInfo.processInfo.environment["OMNIPLAY_MUTE"] != nil {
                arguments += ["--audio-driver", "Dummy"]
            }
            OPLog.log(.runtime, .info, "godot \(bucket.rawValue) for \(entry)", session: configuration.sessionID)
        }

        public func start(in host: any RuntimeHost) async throws {
            guard let configuration, let library else { throw Failure.notPrepared }
            self.host = host
            let cache = configuration.cacheDirectory.appending(path: "godot", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            Self.teachDelegateWindow(host.containerView.window)
            try library.setup(arguments: arguments, userDirectory: configuration.saveDirectory, cacheDirectory: cache)
            guard let raw = library.surface() else { throw Failure.notPrepared }
            // Godot in its own window, like the other native engines' windows.
            let window: UIWindow
            if library.engine == .godot4 {
                guard let scene = host.containerView.window?.windowScene else { throw Failure.notPrepared }
                window = UIWindow(windowScene: scene)
                window.rootViewController = Unmanaged<UIViewController>.fromOpaque(raw).takeUnretainedValue()
            } else {
                window = Unmanaged<UIWindow>.fromOpaque(raw).takeUnretainedValue()
                window.windowScene = host.containerView.window?.windowScene
            }
            window.makeKeyAndVisible()
            self.window = window
            host.adoptEngineWindow(window)

            // Start-up (setup2, the main scene) happens over Godot's first display-link frames.
            let deadline = ContinuousClock.now + .seconds(30)
            while library.frames < 3, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard library.frames >= 3 else { throw Failure.noFrames }
            // Godot's view controller answers with the project's handheld orientation once set up. The host holds it,
            // because the scene asks the app, not Godot, while Godot's window is hidden behind the pause menu; left to
            // follow the device the game came back portrait from Home (Godot 4) or turned with the phone (Godot 3).
            let mask = window.rootViewController?.supportedInterfaceOrientations ?? .all
            let orientation: OrientationPreference =
                mask.isSubset(of: .landscape) ? .landscape : mask.isSubset(of: [.portrait, .portraitUpsideDown]) ? .portrait : .any
            host.lockOrientation(orientation)
            observeLifecycle()
            host.runtimeDidEmit(.gradeReached(.intro))
            OPLog.log(.runtime, .info, "godot drawing, \(orientation)", session: configuration.sessionID)
        }

        /// Godot 3 and 4 read `UIApplication.shared.delegate.window` on every frame once the device's motion sensors
        /// are on, which is always on a phone. The app's delegate answers it; should the delegate UIKit actually holds
        /// (SwiftUI's own, which forwards to the app's) not, it is taught to here, since an unanswered selector is an
        /// exception that ends the whole app, not just the game.
        private static func teachDelegateWindow(_ window: UIWindow?) {
            guard let delegate = UIApplication.shared.delegate as? NSObject else { return }
            let selector = NSSelectorFromString("window")
            guard !delegate.responds(to: selector) else { return }
            weak var fallback = window
            let answer: @convention(block) (AnyObject) -> UIWindow? = { _ in fallback }
            class_addMethod(type(of: delegate), selector, imp_implementationWithBlock(answer), "@@:")
            OPLog.log(.runtime, .info, "app delegate taught to answer window for Godot")
        }

        private func observeLifecycle() {
            observers = EngineAppEvents.observe(memoryWarning: true) { [weak self] event in self?.library?.appEvent(event) }
        }

        public func pause() async {
            let frame = window?.rootViewController?.view.frozenFrame()
            library?.request(.pause)
            host?.showFrozenFrame(frame)
        }

        public func resume() async {
            host?.hideFrozenFrame()
            library?.request(.run)
        }

        /// Keys from the host's touch controls; Godot reads touches and controllers itself.
        public func send(_ input: GameInputEvent) {
            switch input {
            case let .keyDown(key): library?.key(key.godotName, pressed: true)
            case let .keyUp(key): library?.key(key.godotName, pressed: false)
            default: break
            }
        }

        public func handleMemoryPressure(_ level: MemoryPressureLevel) {
            OPLog.log(.memory, .default, "godot session under \(level.rawValue) memory pressure", session: configuration?.sessionID)
            library?.appEvent(4)
        }

        public func stop(reason: RuntimeStopReason) async -> TeardownVerdict {
            guard library != nil, library?.status != .idle else { return .clean }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            host?.hideFrozenFrame()
            library?.request(.stop)
            host?.releaseEngineWindow()
            window?.isHidden = true
            window = nil
            OPLog.log(.runtime, .info, "godot stopped (\(reason)): slotSpent", session: configuration?.sessionID)
            return .slotSpent
        }
    }

    private extension GameKey {
        /// Godot's key name (`find_keycode`): "ArrowUp" → "Up", "KeyZ" → "Z", "ShiftLeft" → "Shift".
        var godotName: String {
            if rawValue.hasPrefix("Arrow") {
                return String(rawValue.dropFirst(5))
            }
            if rawValue.hasPrefix("Key") || rawValue.hasPrefix("Digit") {
                return domKey.uppercased()
            }
            if rawValue == "Space" {
                return "Space"
            }
            if rawValue.hasPrefix("Control") {
                return "Ctrl"
            }
            return domKey
        }
    }
#endif
