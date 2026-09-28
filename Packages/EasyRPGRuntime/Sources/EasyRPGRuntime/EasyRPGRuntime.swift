#if canImport(UIKit)
    import Diagnostics
    import Foundation
    import GameCore
    import InputKit
    import OverlayVFS
    import RuntimeCore
    import SaveKit
    import UIKit

    /// RPG Maker 2000 and 2003 games through the embedded EasyRPG Player.
    ///
    /// The Player reads the game's folder under `Original/` and writes `SaveNN.lsd` into the game's `Saves/slots/`
    /// through `--save-path`, where the Save Manager and backups already look. Its settings file and log go to the
    /// game's cache and log folders, never into the sealed game tree. Keys come from the host's input layer (the
    /// virtual pad and controllers) as SDL scancodes; SDL's window takes touches itself.
    ///
    /// One boot per process until `TEST-009` shows `Player::Exit` and a second `Player::Init` cycle cleanly, so every
    /// stop is `.slotSpent` (or `.restartRequired` if the Player never let go).
    @MainActor
    public final class EasyRPGRuntime: GameRuntime {
        public var onFailure: (@MainActor (String) -> Void)?

        public enum Failure: Error, CustomStringConvertible {
            case notPrepared
            case engineMissing
            case engineAlreadySpent
            case windowMissing
            case engineExited(Int32)

            public var description: String {
                switch self {
                case .notPrepared: "The session was not prepared."
                case .engineMissing: "This build has no EasyRPG Player."
                case .engineAlreadySpent: "EasyRPG already ran this launch. OmniPlay has to restart."
                case .windowMissing: "EasyRPG never opened its window."
                case let .engineExited(status): "EasyRPG stopped before the game appeared (status \(status)); see the session log."
                }
            }
        }

        private var configuration: RuntimeConfiguration?
        private var library: EasyRPGEngineLibrary?
        private var arguments: [String] = []
        private var snapshotURL: URL?
        private weak var host: (any RuntimeHost)?
        private weak var engineWindow: UIWindow?
        private var observers: [NSObjectProtocol] = []
        private var watchdog: NativeWatchdog?
        private var exitStatus: Int32?
        private var stopping = false
        private var adopted = false
        private var lastFrames: UInt = 0
        private var lastRead = ContinuousClock.now

        public init() {}

        // MARK: GameRuntime

        public func prepare(configuration: RuntimeConfiguration) async throws {
            guard let library = EasyRPGEngineLibrary.bundled() else { throw Failure.engineMissing }
            guard library.isAvailable else { throw Failure.engineAlreadySpent }
            self.configuration = configuration
            self.library = library

            let fm = FileManager.default
            let game = configuration.layers.first { $0.tier == .original }?.root
                ?? configuration.indexURL.deletingLastPathComponent().appending(path: "Original")
            let saves = configuration.saveDirectory
            try SaveLocation(savesRoot: saves.deletingLastPathComponent()).ensure()
            try fm.createDirectory(at: configuration.logDirectory, withIntermediateDirectories: true)
            let work = configuration.cacheDirectory.appending(path: "easyrpg", directoryHint: .isDirectory)
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            snapshotURL = work.appending(path: "pause.png")

            arguments = [
                "--project-path", game.path(percentEncoded: false),
                "--save-path", saves.path(percentEncoded: false),
                "--config-path", work.path(percentEncoded: false),
                "--log-file", configuration.logDirectory.appending(path: "easyrpg.log").path(percentEncoded: false),
                "--fullscreen",
                // The host pauses the Player itself; the Player's own focus-lost pause would park it inside SDL
                // whenever a host sheet covers its window.
                "--no-pause-focus-lost",
            ]
            // The user's imported RTP. The Player fingerprints it itself and maps asset names across RTP releases,
            // so a game made with the Japanese RTP still finds its art in an English one.
            if let rtp = configuration.layers.first(where: { $0.tier == .rtp })?.root,
               let entries = try? fm.contentsOfDirectory(atPath: rtp.path(percentEncoded: false)), !entries.isEmpty {
                arguments += ["--rtp-path", rtp.path(percentEncoded: false)]
            }
            // MIDI is 2000/2003's music format; without a soundfont the Player falls back to its FM synth.
            if let font = configuration.profile.overrides["midiSoundFont"] {
                arguments += ["--soundfont", font]
            }
            // Without a hint the Player detects the game's code page itself (ICU's detector over the database).
            if let encoding = configuration.profile.overrides["encoding"] {
                arguments += ["--encoding", encoding]
            }
            OPLog.log(.runtime, .info, "easyrpg for \(game.lastPathComponent)", session: configuration.sessionID)
        }

        public func start(in host: any RuntimeHost) async throws {
            guard let configuration, let library else { throw Failure.notPrepared }
            self.host = host
            // SDL's view controller owns the orientation once its window is key; this is its hint for which ones.
            setenv("SDL_IOS_ORIENTATIONS", host.orientationPreference == .portrait ? "Portrait" : "LandscapeLeft LandscapeRight", 1)
            try library.boot(arguments: arguments) { [weak self] status in self?.engineExited(status: status) }

            // The window appears once Player::Init has read the database. The wait is against the clock: the
            // Player owns the main thread from here on, so a count of short sleeps would not add up.
            let deadline = ContinuousClock.now + .seconds(60)
            while ContinuousClock.now < deadline {
                if let raw = library.window() {
                    attach(Unmanaged<UIWindow>.fromOpaque(raw).takeUnretainedValue(), to: host)
                    adopted = true
                    observeLifecycle()
                    startWatchdog()
                    host.runtimeDidEmit(.gradeReached(.intro))
                    OPLog.log(.runtime, .info, "easyrpg window adopted", session: configuration.sessionID)
                    return
                }
                if let exitStatus {
                    throw Failure.engineExited(exitStatus)
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw Failure.windowMissing
        }

        /// SDL opens its window without a UIScene, which a scene-based app never shows. Placing it in the host's
        /// scene makes it visible and key; the overlay (the virtual pad and pause button) then moves into it.
        private func attach(_ window: UIWindow, to host: any RuntimeHost) {
            if window.windowScene == nil {
                window.windowScene = host.containerView.window?.windowScene
            }
            window.makeKeyAndVisible()
            engineWindow = window
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            host.adoptEngineWindow(window)
            // SDL made the window at the screen's portrait size, and the Player sizes its picture from that at start.
            // The landscape size SDL reports when the window joins the scene arrives while the Player is still loading
            // and is lost, leaving the picture laid out for portrait in a corner. Once it draws, SDL's view is laid
            // out again, so SDL resends the size and the Player takes it.
            Task { @MainActor [library] in
                let deadline = ContinuousClock.now + .seconds(10)
                while library?.frames ?? 0 < 2, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                window.rootViewController?.view.setNeedsLayout()
                window.rootViewController?.view.layoutIfNeeded()
            }
        }

        /// SDL hears about the app's lifecycle from its own app delegate, which OmniPlay is not.
        private func observeLifecycle() {
            let center = NotificationCenter.default
            let events: [(Notification.Name, Int32)] = [
                (UIApplication.willResignActiveNotification, 0),
                (UIApplication.didEnterBackgroundNotification, 1),
                (UIApplication.willEnterForegroundNotification, 2),
                (UIApplication.didBecomeActiveNotification, 3),
            ]
            observers = events.map { name, event in
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let library = self?.library, library.phase == .running else { return }
                        library.appEvent(event)
                    }
                }
            }
        }

        /// The Player has no hang flag of its own; its frame count, read every two seconds, stands in.
        private func startWatchdog() {
            lastRead = .now
            let watchdog = NativeWatchdog(read: { [weak self] in
                guard let self, let library else {
                    return NativeWatchdog.Reading(terminated: true, paused: false, framesPerSecond: 0)
                }
                let now = ContinuousClock.now, frames = library.frames, elapsed = (now - lastRead) / .seconds(1)
                let fps = elapsed > 0 ? Double(frames &- lastFrames) / elapsed : 0
                (lastFrames, lastRead) = (frames, now)
                return NativeWatchdog.Reading(
                    terminated: library.status == .exited,
                    paused: library.status == .paused || stopping,
                    framesPerSecond: fps
                )
            }, onStall: { [weak self] stalled in
                guard let self else { return }
                host?.runtimeDidEmit(.watchdogStalled(seconds: stalled))
                OPLog.log(.runtime, .error, "easyrpg unresponsive for \(Int(stalled))s", session: configuration?.sessionID)
                if stalled >= NativeWatchdog.hangLimit {
                    onFailure?("The game stopped responding. Leaving the game will need OmniPlay to restart.")
                }
            })
            watchdog.start()
            self.watchdog = watchdog
        }

        public func pause() async {
            guard let library, library.status == .running else { return }
            library.request(.pause)
            // The Player stops between frames, a sixtieth of a second away.
            let deadline = ContinuousClock.now + .seconds(2)
            while library.status != .paused, library.phase == .running, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            host?.showFrozenFrame(snapshotImage())
        }

        public func resume() async {
            host?.hideFrozenFrame()
            library?.request(.run)
        }

        private func snapshotImage() -> CGImage? {
            guard let library, let snapshotURL, library.snapshot(to: snapshotURL),
                  let image = UIImage(contentsOfFile: snapshotURL.path(percentEncoded: false)) else { return nil }
            try? FileManager.default.removeItem(at: snapshotURL)
            return image.cgImage
        }

        public func send(_ input: GameInputEvent) {
            guard let library, library.phase == .running else { return }
            switch input {
            case let .keyDown(key): if let code = key.hidUsage {
                    library.key(code, down: true)
                }
            case let .keyUp(key): if let code = key.hidUsage {
                    library.key(code, down: false)
                }
            default: break // pads arrive as keys; pointers go to SDL's window directly
            }
        }

        public func handleMemoryPressure(_ level: MemoryPressureLevel) {
            OPLog.log(.memory, .default, "easyrpg session under \(level.rawValue) memory pressure", session: configuration?.sessionID)
            library?.appEvent(4)
        }

        /// Asks the Player to quit between frames (its own quit path, which ends in Player::Exit and closes SDL's
        /// window) and waits for the call to return.
        public func stop(reason: RuntimeStopReason) async -> TeardownVerdict {
            guard library != nil, library?.phase != .notStarted else { return .clean }
            stopping = true
            watchdog?.stop()
            watchdog = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            host?.hideFrozenFrame()
            library?.request(.stop)
            let deadline = ContinuousClock.now + .seconds(8)
            while library?.phase == .running, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            let verdict: TeardownVerdict = library?.phase == .running ? .restartRequired : .slotSpent
            host?.releaseEngineWindow()
            engineWindow?.isHidden = true
            engineWindow?.windowScene = nil
            OPLog.log(
                .runtime,
                verdict == .restartRequired ? .error : .info,
                "easyrpg stopped (\(reason)): \(verdict)",
                session: configuration?.sessionID
            )
            return verdict
        }

        private func engineExited(status: Int32) {
            exitStatus = status
            OPLog.log(.runtime, status == 0 ? .info : .error, "easyrpg exited with status \(status)", session: configuration?.sessionID)
            // The game's own Shutdown ends the session too; the player screen leaves when it hears about it.
            if adopted, !stopping {
                host?.runtimeDidEmit(.ended(status: status))
            }
        }
    }
#endif
