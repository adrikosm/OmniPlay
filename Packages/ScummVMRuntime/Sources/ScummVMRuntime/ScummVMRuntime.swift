#if canImport(UIKit)
    import Diagnostics
    import Foundation
    import GameCore
    import InputKit
    import OverlayVFS
    import RuntimeCore
    import SaveKit
    import UIKit

    /// Adventure games and interactive fiction through the embedded ScummVM.
    ///
    /// ScummVM stays up between games: a session hands it one game (a config domain with the game's folder under
    /// `Original/` and its `Saves/slots/` as savepath), and leaving normally returns to waiting (`.clean`). An exited
    /// or unresponsive engine needs a process restart. ScummVM reads touches (its direct and touchpad mouse modes), controllers
    /// and hardware keyboards itself; host input is ignored and the virtual pad stays hidden.
    @MainActor
    public final class ScummVMRuntime: GameRuntime {
        public var onFailure: (@MainActor (String) -> Void)?

        public enum Failure: Error, CustomStringConvertible {
            case notPrepared
            case engineMissing
            case busy
            case gameFailed(String)
            case timedOut

            public var description: String {
                switch self {
                case .notPrepared: "The session was not prepared."
                case .engineMissing: "This build has no ScummVM."
                case .busy: "ScummVM is still running another game."
                case let .gameFailed(message): message.isEmpty ? "ScummVM could not start the game." : message
                case .timedOut: "ScummVM did not start the game in time; see the session log."
                }
            }
        }

        private let configFile: URL
        private let soundFont: @MainActor () -> URL?
        private var configuration: RuntimeConfiguration?
        private var library: ScummVMEngineLibrary?
        private var settings: [String: String] = [:]
        private weak var host: (any RuntimeHost)?
        private weak var engineWindow: UIWindow?
        private var observers: [NSObjectProtocol] = []
        private var watchdog: NativeWatchdog?
        private var monitor: Task<Void, Never>?
        private var stopping = false
        /// Between willResignActive and didBecomeActive ScummVM sits in its suspend loop and counts no frames.
        private var inactive = false
        private var fps = FrameRateSampler()

        /// `configFile` is ScummVM's process-wide settings file (the one detection uses too); `soundFont` the MIDI
        /// soundfont OmniPlay uses for every engine (the player's import, else the bundled one).
        public init(configFile: URL, soundFont: @escaping @MainActor () -> URL?) {
            self.configFile = configFile
            self.soundFont = soundFont
        }

        // MARK: GameRuntime

        public func prepare(configuration: RuntimeConfiguration) async throws {
            guard let library = ScummVMEngineLibrary.bundled() else { throw Failure.engineMissing }
            self.configuration = configuration
            self.library = library
            let game = configuration.originalRoot
            try configuration.ensureSessionDirectories()

            settings = [
                "path": ScummVMEngineLibrary.scummPath(game),
                "savepath": ScummVMEngineLibrary.scummPath(configuration.saveDirectory),
                "description": configuration.descriptor.title,
            ]
            // Detection's answer from import; without it ScummVM detects the folder again before starting.
            let overrides = configuration.profile.overrides
            for key in ["engineid", "gameid", "language", "platform"] {
                if let value = overrides["scummvm.\(key)"], !value.isEmpty {
                    settings[key] = value
                }
            }
            // ScummVM's window decides the orientation once it is key, and opens its keyboard in portrait: it gets the
            // same answer as the host (interactive fiction portrait, everything else landscape).
            settings["orientation_games"] = settings["engineid"] == "glk" ? "portrait" : "landscape"
            // The player's mouse mode (INPUT-008); ScummVM's own default on a phone is the touchpad.
            if let mode = overrides["mouseMode"], mode == "direct" || mode == "touchpad" {
                settings["touch_mode_2d_games"] = mode
                settings["touch_mode_3d_games"] = mode
            }
            // FluidSynth opens the soundfont itself, so it needs a path that resolves to a real file: ScummVM's
            // default (a bare name found through its search path) does not, and fails with a modal dialog.
            if let font = soundFont().map(ScummVMEngineLibrary.scummPath) {
                settings["soundfont"] = font
            }
            OPLog.log(
                .runtime,
                .info,
                "scummvm for \(game.lastPathComponent): \(settings["gameid"] ?? "detect")",
                session: configuration.sessionID
            )
        }

        public func start(in host: any RuntimeHost) async throws {
            guard let configuration, let library else { throw Failure.notPrepared }
            self.host = host
            if !library.isStarted {
                try ScummVMEngineLibrary.writeConfig(to: configFile, muted: ProcessInfo.processInfo.environment["OMNIPLAY_MUTE"] != nil)
            }
            try library.setLog(configuration.logDirectory.appending(path: "scummvm.log"))
            try await library.startIfNeeded(configFile: configFile)
            guard library.status == .waiting else { throw Failure.busy }
            if let raw = library.window() {
                attach(Unmanaged<UIWindow>.fromOpaque(raw).takeUnretainedValue(), to: host)
            }
            guard library.play(settings) else { throw Failure.busy }

            // Identification, engine start-up and the first frame; a game ScummVM cannot run falls back to waiting.
            let deadline = ContinuousClock.now + .seconds(60)
            while ContinuousClock.now < deadline {
                switch library.status {
                case .playing:
                    observeLifecycle()
                    startWatchdog()
                    startMonitor()
                    host.runtimeDidEmit(.gradeReached(.intro))
                    OPLog.log(.runtime, .info, "scummvm playing \(settings["gameid"] ?? "?")", session: configuration.sessionID)
                    return
                case .waiting:
                    releaseWindow()
                    throw Failure.gameFailed(library.lastResult().message)
                default:
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            throw Failure.timedOut
        }

        /// ScummVM's window has no scene; placing it in the host's makes it visible, and the overlay moves into it.
        private func attach(_ window: UIWindow, to host: any RuntimeHost) {
            window.windowScene = host.containerView.window?.windowScene
            window.frame = window.windowScene?.coordinateSpace.bounds ?? window.frame
            window.isHidden = false
            window.makeKeyAndVisible()
            engineWindow = window
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            host.adoptEngineWindow(window)
        }

        private func releaseWindow() {
            host?.releaseEngineWindow(engineWindow)
            engineWindow = nil
        }

        private func observeLifecycle() {
            observers = EngineAppEvents.observe { [weak self] event in self?.lifecycle(event) }
        }

        private func lifecycle(_ event: Int32) {
            library?.appEvent(event)
            if event == 0 {
                inactive = true
            }
            if event == 3 {
                inactive = false
                // Measure from now, not across the suspension.
                fps = FrameRateSampler(frames: library?.frames ?? 0)
            }
        }

        /// ScummVM polls events at least once a frame; the shim counts polls, read every two seconds.
        private func startWatchdog() {
            fps = FrameRateSampler(frames: library?.frames ?? 0)
            let watchdog = NativeWatchdog(read: { [weak self] in
                guard let self, let library else {
                    return NativeWatchdog.Reading(terminated: true, paused: false, framesPerSecond: 0)
                }
                return NativeWatchdog.Reading(
                    terminated: library.status == .exited,
                    paused: library.status != .playing || stopping || inactive,
                    framesPerSecond: fps.sample(library.frames)
                )
            }, onStall: { [weak self] stalled in
                guard let self else { return }
                NativeWatchdog.report(stalled, engine: "scummvm", host: host, session: configuration?.sessionID, onFailure: onFailure)
            })
            watchdog.start()
            self.watchdog = watchdog
        }

        /// A game can end by itself (its own Quit, or an engine error); ScummVM then goes back to waiting.
        private func startMonitor() {
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self, let library, !stopping else { return }
                    if library.status == .waiting || library.status == .exited {
                        let result = library.lastResult()
                        OPLog.log(
                            .runtime,
                            result.code == 0 ? .info : .error,
                            "scummvm game ended (\(result.code)) \(result.message)",
                            session: configuration?.sessionID
                        )
                        if result.code != 0 {
                            onFailure?(result.message)
                        }
                        host?.runtimeDidEmit(.ended(status: result.code))
                        return
                    }
                }
            }
        }

        public func pause() async {
            guard let library, library.status == .playing else { return }
            let frame = engineWindow?.rootViewController?.view.frozenFrame()
            library.request(.pause)
            host?.showFrozenFrame(frame)
        }

        public func resume() async {
            host?.hideFrozenFrame()
            library?.request(.run)
        }

        public func handleMemoryPressure(_ level: MemoryPressureLevel) {
            OPLog.log(.memory, .default, "scummvm session under \(level.rawValue) memory pressure", session: configuration?.sessionID)
        }

        /// Leaves the game through ScummVM's return-to-launcher, which ends in waiting for the next one.
        public func stop(reason: RuntimeStopReason) async -> TeardownVerdict {
            stopping = true
            monitor?.cancel()
            watchdog?.stop()
            watchdog = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            host?.hideFrozenFrame()
            // Once scummvm_main returns the native shim cannot boot again in this process.
            var verdict: TeardownVerdict = library?.status == .exited ? .slotSpent : .clean
            if let library, library.status == .notStarted, library.bootInvoked {
                // The native thread was created but never reached its waiting loop; it may still start late.
                verdict = .restartRequired
            }
            if let library, library.status == .playing || library.status == .paused || library.status == .starting {
                library.request(.leave)
                let deadline = ContinuousClock.now + .seconds(8)
                while library.status != .waiting, library.status != .exited, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                switch library.status {
                case .waiting: verdict = .clean
                case .exited: verdict = .slotSpent
                default: verdict = .restartRequired
                }
            }
            releaseWindow()
            OPLog.log(
                .runtime,
                verdict == .clean ? .info : .error,
                "scummvm stopped (\(reason)): \(verdict)",
                session: configuration?.sessionID
            )
            return verdict
        }
    }

    extension ScummVMRuntime: EngineMenuCapable {
        public var engineMenuTitle: String { "ScummVM menu (save, load, options)" }
        public func openEngineMenu() { library?.openMainMenu() }
    }
#endif
