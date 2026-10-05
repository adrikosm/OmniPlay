#if canImport(UIKit)
    import Diagnostics
    import Foundation
    import GameCore
    import InputKit
    import OverlayVFS
    import RuntimeCore
    import SaveKit
    import UIKit

    /// Ren'Py games through one of the embedded engines (8.5.3 / Python 3.12, 8.3.7 / Python 3.9,
    /// 7.8.7 / Python 2.7); the resolver picks which, the player never does.
    ///
    /// The engine is pointed at the game's own folder under `Original/` and finds `game/` there by itself. Saves
    /// and persistent data go to the game's `Saves/slots/` through Ren'Py's `--savedir`, without save tokens, so
    /// saves imported from a PC load with no prompt. Everything Ren'Py-side lives in the framework's
    /// `base/omniplay_host.py`; this adapter only hands it paths.
    ///
    /// SDL's window takes touches, the keyboard and controllers itself, which is what Ren'Py's own gestures
    /// and pad bindings expect. The engine boots once per process; leaving a game parks it inside Ren'Py's own
    /// restart loop, and the next game on the same engine starts there without a relaunch (`.clean`). Only Python
    /// ending (`.slotSpent`) or a hang (`.restartRequired`) costs the engine.
    @MainActor
    public final class RenPyRuntime: GameRuntime {
        public let engine: RenPyEngine

        public enum Failure: Error, CustomStringConvertible {
            case notPrepared
            case engineMissing(RenPyEngine)
            case engineAlreadySpent
            case windowMissing
            case engineExited(Int32)
            case gameEndedAtStart

            public var description: String {
                switch self {
                case .notPrepared: "The session was not prepared."
                case let .engineMissing(engine): "This build has no Ren'Py \(engine.version) engine."
                case .engineAlreadySpent: "This Ren'Py engine already ran this launch. OmniPlay has to restart."
                case .windowMissing: "Ren'Py never opened its window."
                case let .engineExited(status): "Ren'Py stopped before the game appeared (status \(status)); see the session log."
                case .gameEndedAtStart: "The game ended before it appeared; its traceback is in the session log."
                }
            }
        }

        var configuration: RuntimeConfiguration?
        var library: RenPyEngineLibrary?
        var session: RenPyEngineLibrary.Session?
        var arguments: [String] = []
        var environment: [String: String?] = [:]
        var snapshot: URL?
        var watch: Task<Void, Never>?
        weak var host: (any RuntimeHost)?
        weak var engineWindow: UIWindow?
        var exitStatus: Int32?
        var stopping = false
        var adopted = false
        var observers: [NSObjectProtocol] = []
        /// Live translation: translations waiting for the next mailbox visit, and the visiting task.
        var liveOut: [String: String] = [:]
        var livePoll: Task<Void, Never>?
        public var onMissedText: (@MainActor (String) -> Void)? {
            didSet { startLivePoll() }
        }

        /// The pause menu's skip mode (1 off, 2 seen text, 3 all text); Ren'Py drops out of it at the next choice.
        public internal(set) var fastForward = 1

        public init(engine: RenPyEngine) {
            self.engine = engine
        }

        // MARK: GameRuntime

        public func prepare(configuration: RuntimeConfiguration) async throws {
            guard let library = RenPyEngineLibrary.bundled(engine) else { throw Failure.engineMissing(engine) }
            // A game left while still loading parks once Python reaches its first tick (see `stop`).
            let parking = ContinuousClock.now + .seconds(30)
            while library.phase == .running, library.status == .booting, ContinuousClock.now < parking {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard library.isAvailable else { throw Failure.engineAlreadySpent }
            self.configuration = configuration
            self.library = library

            let fm = FileManager.default
            let original = configuration.originalRoot
            let saves = configuration.saveDirectory
            try configuration.ensureSessionDirectories()
            // Writable space the engine needs outside the sealed game tree: the host script and its .rpyc, the
            // caches Ren'Py builds (bytecode, shaders), and the frame shown while paused.
            let work = configuration.cacheDirectory.appending(path: "renpy", directoryHint: .isDirectory)
            let cache = work.appending(path: "cache", directoryHint: .isDirectory)
            try fm.createDirectory(at: cache, withIntermediateDirectories: true)
            let snapshot = work.appending(path: "pause.png")
            try? fm.removeItem(at: snapshot)
            self.snapshot = snapshot

            // Mods and generated media mirror the game's root; their game/ folders go in front of the original.
            let overlays = configuration.layers
                .filter { $0.tier == .overrides || $0.tier == .generated }
                .sorted { $0.priority > $1.priority }
                .map { $0.root.appending(path: "game", directoryHint: .isDirectory) }
                .filter { fm.fileExists(atPath: $0.path(percentEncoded: false)) }

            let log = configuration.logDirectory.appending(path: "python.log").path(percentEncoded: false)
            session = RenPyEngineLibrary.Session(
                basedir: original.path(percentEncoded: false),
                savedir: saves.path(percentEncoded: false),
                logdir: configuration.logDirectory.path(percentEncoded: false),
                log: log,
                hostdir: work.appending(path: "host", directoryHint: .isDirectory).path(percentEncoded: false),
                cachedir: cache.path(percentEncoded: false),
                snapshot: snapshot.path(percentEncoded: false),
                overlays: overlays.map { $0.path(percentEncoded: false) },
                keep: library.mayPark
            )
            session?.writedir = configuration.persistentDirectory.appending(path: "game-files", directoryHint: .isDirectory)
                .path(percentEncoded: false)
            // Developer switches from Ren'Py Tools, applied by the host script at init 999.
            for name in RenPyEngineLibrary.Session.switchNames where configuration.profile.overrides["renpy.\(name)"] == "1" {
                session?.switches[name] = true
            }
            session?.translation = configuration.profile.overrides["translationDictionaryFile"]
            session?.language = configuration.profile.overrides["translationLanguage"]
            session?.cjkFont = configuration.profile.overrides["cjkFontFile"]
            session?.liveTranslation = !(configuration.profile.overrides["liveTranslation"] ?? "").isEmpty
            // Converted before launch (AppModel+Media); Ren'Py names files relative to game/.
            if let json = configuration.profile.overrides["mediaRemap"]?.data(using: .utf8),
               let remap = try? JSONDecoder().decode([String: String].self, from: json),
               let generated = configuration.layers.first(where: { $0.tier == .generated })?.root {
                // A conversion lives in Generated; a playable sibling the game already ships, in the game itself.
                for (source, target) in remap where source.hasPrefix("game/") {
                    let converted = generated.appending(path: target)
                    let file = fm.fileExists(atPath: converted.path(percentEncoded: false)) ? converted : original.appending(path: target)
                    session?.remap[String(source.dropFirst(5))] = file.path(percentEncoded: false)
                }
            }
            // What Python reads before the session exists (the first game's log) and what Ren'Py and SDL read for
            // themselves; the rest travels in the session.
            environment = [
                "OMNIPLAY_RENPY_LIBRARY": library.binaryURL.path(percentEncoded: false),
                "OMNIPLAY_RENPY_LOG": log,
                "RENPY_SEARCHPATH": nil,
                "RENPY_PLATFORM": "ios-arm64",
            ]
            arguments = [original.path(percentEncoded: false)]
            OPLog.log(
                .python,
                .info,
                "ren'py \(engine.version) for \(original.lastPathComponent), \(overlays.count) overlay folders",
                session: configuration.sessionID
            )
        }

        public func start(in host: any RuntimeHost) async throws {
            guard let configuration, let library, let session else { throw Failure.notPrepared }
            self.host = host
            // SDL's view controller owns the orientation once its window is key; this is its hint for which ones.
            environment["SDL_IOS_ORIENTATIONS"] = host.orientationPreference == .portrait
                ? "Portrait PortraitUpsideDown" : "LandscapeLeft LandscapeRight"

            library.onExit = { [weak self] status in self?.engineExited(status: status) }
            // A parked engine still has the previous game's window, showing its last frame; it stays hidden until
            // the new game is running.
            let switching = library.phase == .running
            if switching {
                try library.switchGame(session: session, environment: environment)
                let game = URL(filePath: session.basedir).lastPathComponent
                OPLog.log(.python, .info, "parked engine switched to \(game)", session: configuration.sessionID)
            } else {
                try library.boot(session: session, arguments: arguments, environment: environment)
            }

            // Ren'Py opens its window after loading the game's scripts, which for a large game on a phone takes
            // a while. The wait is against the clock: the engine owns the main thread from here on, so a count
            // of short sleeps would not add up to the time it claims.
            let deadline = ContinuousClock.now + .seconds(120)
            while ContinuousClock.now < deadline {
                if let raw = library.window(), !switching || library.status == .running {
                    let window = Unmanaged<UIWindow>.fromOpaque(raw).takeUnretainedValue()
                    attach(window, to: host)
                    adopted = true
                    observeLifecycle()
                    watchForGameEnd()
                    host.runtimeDidEmit(.gradeReached(.intro))
                    OPLog.log(.python, .info, "engine window adopted", session: configuration.sessionID)
                    return
                }
                if let exitStatus {
                    throw Failure.engineExited(exitStatus)
                }
                if library.status == .parked {
                    throw Failure.gameEndedAtStart
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw Failure.windowMissing
        }

        /// A game that quits by itself parks the engine without telling anyone; the player screen leaves when this
        /// notices, a quarter of a second later at most.
        func watchForGameEnd() {
            watch = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, !stopping, let library else { return }
                    if library.status == .parked {
                        OPLog.log(.python, .info, "game ended by itself; engine parked", session: configuration?.sessionID)
                        host?.runtimeDidEmit(.ended(status: 0))
                        return
                    }
                }
            }
        }

        /// SDL hears about the app's lifecycle from its own app delegate, which OmniPlay is not. Ren'Py saves and
        /// pauses its audio when told the app is leaving the foreground, so the four events are passed on.
        func observeLifecycle() {
            observers = EngineAppEvents.observe { [weak self] event in
                guard let library = self?.library, library.phase == .running, library.status != .parked else { return }
                library.appEvent(event)
            }
        }

        /// SDL 2.0.20 predates UIScene and opens its window without one, which a scene-based app never shows.
        /// Placing it in the host's scene makes it visible and key; the overlay then moves into it.
        func attach(_ window: UIWindow, to host: any RuntimeHost) {
            if window.windowScene == nil {
                window.windowScene = host.containerView.window?.windowScene
            }
            window.makeKeyAndVisible()
            engineWindow = window
            // Attaching a window does not rotate the scene by itself; ask for the orientations SDL now reports.
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            let orientations: UIInterfaceOrientationMask = host.orientationPreference == .portrait ? .portrait : .landscape
            window.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: orientations))
            host.adoptEngineWindow(window)
        }

        public func pause() async {
            guard let library, library.phase == .running, library.status == .running else { return }
            library.request(.pause)
            // The engine stops at its next periodic tick, about 50 ms away, after writing the frame it shows.
            let deadline = ContinuousClock.now + .seconds(2)
            while library.status != .paused, library.phase == .running, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            // `stop` may have run while this waited; it already took the frozen frame down.
            guard !stopping else { return }
            host?.showFrozenFrame(snapshotImage())
        }

        public func resume() async {
            host?.hideFrozenFrame()
            library?.request(.run)
        }

        func snapshotImage() -> CGImage? {
            snapshot.flatMap(CGImage.takeFrame(at:))
        }

        public func handleMemoryPressure(_ level: MemoryPressureLevel) {
            OPLog.log(.memory, .default, "ren'py session under \(level.rawValue) memory pressure", session: configuration?.sessionID)
            library?.appEvent(4)
        }

        /// Asks Ren'Py to quit the game at its next tick and waits for the engine to park, ready for another game.
        /// Python ending instead spends the engine; still running after eight seconds means hung, and Python
        /// cannot be stopped from outside, so the app needs a restart.
        public func stop(reason: RuntimeStopReason) async -> TeardownVerdict {
            guard library != nil, library?.phase != .notStarted else { return .clean }
            stopping = true
            watch?.cancel()
            watch = nil
            livePoll?.cancel()
            livePoll = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            host?.hideFrozenFrame()
            library?.request(.stop)
            let deadline = ContinuousClock.now + .seconds(8)
            while library?.phase == .running, library?.status != .parked, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            let verdict: TeardownVerdict = switch (library?.phase, library?.status) {
            case (.running?, .parked?): .clean
            // Still loading the game: Python honours the stop at its first tick and parks, and `isAvailable` holds
            // the next game until it has. Only a game past loading that does not answer needs a restart.
            case (.running?, .booting?): .clean
            case (.running?, _): .restartRequired
            default: .slotSpent
            }
            // SDL leaves its window up with the last frame after Ren'Py quits; it must not outlive the session.
            host?.releaseEngineWindow(engineWindow)
            OPLog.log(
                .python,
                verdict == .restartRequired ? .error : .info,
                "ren'py stopped (\(reason)): \(verdict)",
                session: configuration?.sessionID
            )
            return verdict
        }

        func engineExited(status: Int32) {
            exitStatus = status
            OPLog.log(.python, status == 0 ? .info : .error, "ren'py exited with status \(status)", session: configuration?.sessionID)
            // The game's own Quit ends the session too; the player screen leaves when it hears about it.
            if adopted, !stopping {
                host?.runtimeDidEmit(.ended(status: status))
            }
        }
    }
#endif
