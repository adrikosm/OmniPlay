#if canImport(UIKit)
    import CMkxpBridge
    import Diagnostics
    import Foundation
    import GameCore
    import InputKit
    import RuntimeCore
    import SaveKit
    import UIKit

    /// RPG Maker XP / VX / VX Ace through the mkxp-z fork.
    ///
    /// The engine boots once per app launch and dies with the session (`RGSSEngineProcess`), so every stop
    /// reports `.slotSpent`. The adapter speaks only `app_bridge.h`: configuration setters before
    /// `mkxp_setGamePath`, callbacks from the engine thread hopped onto the main actor after. No C++ crosses
    /// into Swift, and Swift never reaches around the bridge into SDL.
    @MainActor
    public final class RGSSRuntime: GameRuntime, FastForwardCapable {
        public let ruby: RubyLine
        /// `Assets.bundle` inside the app: the engine's shaders, fonts and preload/postload Ruby.
        public let assets: URL

        public enum Failure: Error, CustomStringConvertible {
            case notPrepared
            case engineNotLinked
            case engineAlreadySpent
            case unsupportedGeneration(Int)
            case windowMissing
            case engineExited(Int32)
            case damagedArchive(RGSSArchive.Invalid)

            public var description: String {
                switch self {
                case .notPrepared: "The session was not prepared."
                case .engineNotLinked: "This build has no RPG Maker engine."
                case .engineAlreadySpent: "The RPG Maker engine already ran this launch. OmniPlay has to restart."
                case let .unsupportedGeneration(v): "This build cannot run RGSS\(v)."
                case .windowMissing: "The engine never opened its window."
                case let .engineExited(status): "The engine stopped before the game appeared (status \(status))."
                case let .damagedArchive(invalid): invalid.description
                }
            }
        }

        var configuration: RuntimeConfiguration?
        var session: RGSSSessionConfig?
        weak var host: (any RuntimeHost)?
        var watchdog: NativeWatchdog?
        var terminated = false
        var exitStatus: Int32?
        /// Set once SDL's window is ours; an exit before that is a boot failure the start path reports itself.
        var adopted = false
        var stopping = false
        public var onFailure: (@MainActor (String) -> Void)?

        public init(ruby: RubyLine, assets: URL) {
            self.ruby = ruby
            self.assets = assets
        }

        // MARK: GameRuntime

        public func prepare(configuration: RuntimeConfiguration) async throws {
            guard RGSSEngineProcess.isLinked else { throw Failure.engineNotLinked }
            guard RGSSEngineProcess.phase == .notStarted else { throw Failure.engineAlreadySpent }
            self.configuration = configuration

            let original = configuration.originalRoot
            let soundFont = configuration.profile.overrides["midiSoundFont"].map { URL(filePath: $0) }
            var session = RGSSSessionConfig(
                descriptor: configuration.descriptor,
                ruby: ruby,
                layers: configuration.layers,
                gameFolder: original,
                soundFont: soundFont
            )
            guard RGSSEngineProcess.supports(rgssVersion: session.rgssVersion) else {
                throw Failure.unsupportedGeneration(session.rgssVersion)
            }
            // The engine parses the game's archive in this process and trusts its lengths; a damaged one corrupts
            // memory long before anything faults, so it is refused here (RGSSArchive).
            do {
                try RGSSArchive.validateArchives(in: original)
            } catch let invalid as RGSSArchive.Invalid {
                OPLog.log(.ruby, .error, "refused: \(invalid)", session: configuration.sessionID)
                throw Failure.damagedArchive(invalid)
            }
            // Everything the host generates for the engine lives outside the imported tree.
            let managed = configuration.cacheDirectory.appending(path: "rgss", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
            session.hostPreloads = try RGSSHostScripts.install(
                in: managed, mediaRemap: configuration.profile.overrides["mediaRemap"],
                translation: configuration.profile.overrides["translationDictionaryFile"]
            )
            self.session = session
            let configFile = try session.write(to: managed)
            try configuration.ensureSessionDirectories()

            mkxp_resetSessionState()
            mkxp_setCABundlePath(assets.appending(path: "cacert.pem").path(percentEncoded: false))
            mkxp_setLauncherIdentity("OmniPlay")
            mkxp_setDebugLogPath(configuration.logDirectory.appending(path: "engine.log").path(percentEncoded: false))
            // Managed config, fonts, Ruby, network, and the save folder: RGSS writes `Save01.rvdata` with a relative
            // name, and the engine routes those to the user-data directory instead of the cwd.
            applySessionConfig(session, managedConfigDir: managed)
            // The host owns controllers (InputKit reads them and sends key events), touch reaches the game as a
            // mouse only while a profile asks for it, and nothing this app runs may open a socket by itself.
            mkxp_setGameControllerCaptureEnabled(false)
            // Touches are the mouse only in direct mode; the host's touchpad layer sends its own pointer events.
            let mouseMode = configuration.profile.overrides["mouseMode"]
            mkxp_setTouchMouseEnabled(mouseMode == nil ? configuration.profile.overrides["touchMouse"] != "false" : mouseMode == "direct")
            mkxp_setCheatsEnabled(configuration.profile.overrides["cheats"] == "true")
            mkxp_installFatalErrorHandlers()
            OPLog.log(
                .ruby,
                .info,
                "rgss\(session.rgssVersion) on \(ruby.rawValue), \(session.patches.count) overlay roots, "
                    + "config \(configFile.path(percentEncoded: false))",
                session: configuration.sessionID
            )
        }

        /// The struct form of the per-boot settings. Every string has to outlive the call, hence the nesting.
        func applySessionConfig(_ session: RGSSSessionConfig, managedConfigDir: URL) {
            guard let configuration else { return }
            let syntax = RGSSSessionConfig.syntaxTransform(named: configuration.profile.overrides["syntaxCompatibilityMode"])
                ?? session.syntaxTransform
            managedConfigDir.path(percentEncoded: false).withCString { managed in
                configuration.saveDirectory.path(percentEncoded: false).withCString { userData in
                    assets.appending(path: "Fonts").path(percentEncoded: false).withCString { fonts in
                        var config = MKXPSessionConfig(
                            managedConfigDir: managed,
                            userDataDirectory: userData,
                            sharedFontsDirectory: fonts,
                            rubyVersion: session.rubyVersion,
                            syntaxTransformMode: syntax,
                            verticalAlignment: MKXP_VALIGN_CENTER,
                            postloadEnabled: true,
                            useInGameKeyboard: session.useInGameKeyboard,
                            joiplayCompat: session.joiplayCompat,
                            networkEnabled: session.networkEnabled
                        )
                        mkxp_applySessionConfig(&config)
                    }
                }
            }
        }

        public func start(in host: any RuntimeHost) async throws {
            guard let configuration, let session else { throw Failure.notPrepared }
            self.host = host
            installCallbacks()
            applyGeometry(host)

            // Released before the engine boots, so `mkxp_waitForGamePath` returns on its first check.
            mkxp_setGamePath(session.gameFolder.path(percentEncoded: false))
            // mkxp-z asks SDL for every orientation; the environment outranks that hint, so SDL's window keeps to the
            // host's lock instead of turning portrait under a landscape host and drawing off-screen (as EasyRPG does).
            let orientations = switch host.orientationPreference {
            case .landscape: "LandscapeLeft LandscapeRight"
            case .portrait: "Portrait"
            case .any: "Portrait LandscapeLeft LandscapeRight"
            }
            setenv("SDL_IOS_ORIENTATIONS", orientations, 1)
            try RGSSEngineProcess.boot(session: configuration.sessionID) { [weak self] status in
                self?.engineExited(status: status)
            }

            // SDL makes its own window key, which puts it above the app's; the overlay moves into it so the
            // pause button and the touch controls stay on top of the picture. The wait is against the clock and
            // not a count of sleeps: the engine owns the main thread from here on, so a 50 ms sleep can take far
            // longer to resume and a loop counter silently turns into a budget nobody chose. Thirty seconds
            // covers a cold boot — SDL, ANGLE, OpenAL and a Ruby VM — which measured about eleven.
            let deadline = ContinuousClock.now + .seconds(30)
            while ContinuousClock.now < deadline {
                if let raw = mkxp_getSDLUIKitWindow() {
                    let window = Unmanaged<UIWindow>.fromOpaque(raw).takeUnretainedValue()
                    host.adoptEngineWindow(window)
                    adopted = true
                    startWatchdog()
                    host.runtimeDidEmit(.gradeReached(.intro))
                    OPLog.log(.ruby, .info, "engine window adopted; ruby \(engineRubyVersion)", session: configuration.sessionID)
                    return
                }
                if let exitStatus {
                    throw Failure.engineExited(exitStatus)
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw Failure.windowMissing
        }

        public func pause() async {
            guard mkxp_isEngineTerminated() == 0 else { return }
            mkxp_requestPause()
            // The engine only stops at a Graphics blocking point. Two seconds is the roadmap's cap; after it the
            // host shows the menu anyway, because a player who cannot reach Exit is worse off than one who
            // pauses a frame late.
            for _ in 0 ..< 40 where !mkxp_isPaused() {
                try? await Task.sleep(for: .milliseconds(50))
            }
            // `stop` may have run while this waited; it already took the frozen frame down.
            guard !stopping else { return }
            host?.showFrozenFrame(snapshotImage())
        }

        public func resume() async {
            host?.hideFrozenFrame()
            mkxp_requestResume()
        }

        /// The RGBA frame the engine captured before it blocked. Copied once into a `CGImage` and released;
        /// at 1080p the buffer is 8 MiB and never outlives this function.
        func snapshotImage() -> CGImage? {
            var width: Int32 = 0, height: Int32 = 0
            guard mkxp_getSnapshotSize(&width, &height), width > 0, height > 0 else { return nil }
            let count = Int(width) * Int(height) * 4
            var pixels = [UInt8](repeating: 0, count: count)
            let copied = pixels.withUnsafeMutableBufferPointer {
                mkxp_copySnapshotRGBA($0.baseAddress, Int32(count), &width, &height)
            }
            guard copied, let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
            return CGImage(
                width: Int(width),
                height: Int(height),
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: Int(width) * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        }

        /// 1× off, 2–9× active. The engine scales its frame limiter; nothing else changes.
        public func setFastForward(_ multiplier: Int) {
            mkxp_setFastForwardMultiplier(Int32(max(1, min(9, multiplier))))
        }

        public var fastForward: Int { Int(mkxp_getFastForwardMultiplier()) }

        public func send(_ input: GameInputEvent) {
            guard mkxp_isEngineTerminated() == 0 else { return }
            switch input {
            case let .keyDown(key):
                if let code = RGSSKeyMap.scancode(for: key) {
                    mkxp_injectKeyEvent(code, 1)
                }
            case let .keyUp(key):
                if let code = RGSSKeyMap.scancode(for: key) {
                    mkxp_injectKeyEvent(code, 0)
                }
            case let .pointerDown(_, x, y): injectPointer(x, y, MKXP_POINTER_DOWN)
            case let .pointerMove(x, y): injectPointer(x, y, MKXP_POINTER_MOVE)
            case let .pointerUp(_, x, y): injectPointer(x, y, MKXP_POINTER_UP)
            // SDL's window is the key window, so the engine raises its own keyboard; this is for host-sent text.
            case let .text(text): mkxp_pushTextInput(text)
            case .controllerButton, .controllerAxis:
                // InputKit already turns pad input into keys for keyboard engines; raw pad events are not ours.
                break
            }
        }

        /// Window points, which is what `mkxp_injectPointerEvent` documents. InputKit reports view coordinates,
        /// and for this runtime the view and the engine's window are the same screen.
        func injectPointer(_ x: Double, _ y: Double, _ phase: MKXPPointerPhase) {
            mkxp_injectPointerEvent(Int32(x.rounded()), Int32(y.rounded()), phase)
        }

        public func handleMemoryPressure(_ level: MemoryPressureLevel) {
            OPLog.log(.memory, .default, "rgss session under \(level.rawValue) memory pressure", session: configuration?.sessionID)
        }

        /// Asks the engine to leave and waits for it. A session still alive after eight seconds is hung: the
        /// Ruby thread cannot be killed from outside, so the honest answer is that the app needs a restart.
        public func stop(reason: RuntimeStopReason) async -> TeardownVerdict {
            guard RGSSEngineProcess.phase != .notStarted else { return .clean }
            stopping = true
            watchdog?.stop()
            watchdog = nil
            host?.hideFrozenFrame()
            mkxp_requestResume()
            mkxp_requestTerminate()
            // Against the clock, like the window wait: the engine still owns the main thread, so counting
            // sleeps would not give the eight seconds it looks like. Eight sits under the coordinator's own
            // ten-second cap, which is what actually releases the adapter if this never returns.
            let deadline = ContinuousClock.now + .seconds(8)
            while !terminated, mkxp_isEngineTerminated() == 0, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            let hung = mkxp_isEngineHung() != 0 || (mkxp_isEngineTerminated() == 0 && !terminated)
            host?.releaseEngineWindow()
            OPLog.log(
                .ruby,
                hung ? .error : .info,
                "rgss engine stopped (\(reason)) hung=\(hung) clean=\(mkxp_didEngineExitCleanly() != 0)",
                session: configuration?.sessionID
            )
            return hung ? .restartRequired : .slotSpent
        }

        public var engineRubyVersion: String { mkxp_getRubyVersion().map { String(cString: $0) } ?? "unknown" }

        // MARK: Geometry

        func applyGeometry(_ host: any RuntimeHost) {
            let insets = host.containerView.safeAreaInsets
            mkxp_setSafeAreaInsets(Float(insets.top), Float(insets.bottom), Float(insets.left), Float(insets.right))
        }

        // MARK: Engine callbacks (fire on the engine thread; everything hops to the main actor)

        /// The callbacks are top-level functions on purpose. A closure written inside this class would inherit
        /// its `@MainActor` isolation, and Swift 6 puts an executor assertion at the entry of an isolated
        /// closure — which the engine thread trips the first time it calls one, taking the app down with
        /// `dispatch_assert_queue`. Top-level functions are non-isolated, and `hop` does the crossing.
        func installCallbacks() {
            // Retained for the rest of the process on purpose. The coordinator lets go of the adapter after a clean
            // `.slotSpent` stop, while the engine thread may still be about to report its termination; an unretained
            // pointer would then name a freed object. The engine boots once per process, so this keeps one adapter.
            let box = Unmanaged.passRetained(self).toOpaque()
            mkxp_setEngineTerminatedCallback(rgssEngineTerminated, box)
            mkxp_setErrorMessageCallback(rgssEngineError, box)
            mkxp_setInfoMessageCallback(rgssEngineInfo, box)
        }

        func engineTerminated() {
            terminated = true
            let clean = mkxp_didEngineExitCleanly() != 0
            host?.runtimeDidEmit(.log(.ruby, clean ? "engine exited cleanly" : "engine terminated"))
            if !clean, exitStatus == nil {
                onFailure?("The game closed unexpectedly.")
            }
        }

        func engineExited(status: Int32) {
            exitStatus = status
            terminated = true
            if status != 0 {
                onFailure?("The game engine stopped with an error. The session log has the details.")
            }
            // The game's own Shutdown, or a script that gave up (a missing RTP file ends with status 0): either way
            // the picture is gone, so the player screen has to hear about it rather than sit on black.
            if adopted, !stopping {
                host?.runtimeDidEmit(.ended(status: status))
            }
        }

        /// The engine blocks on its own thread until the message is dismissed, so this must not wait on the user.
        func engineError(_ message: String) {
            host?.runtimeDidEmit(.log(.ruby, "[error] \(message)"))
            OPLog.log(.ruby, .error, message, session: configuration?.sessionID)
            onFailure?(message)
            mkxp_signalErrorDismissed()
        }

        func engineInfo(_ message: String) {
            host?.runtimeDidEmit(.log(.ruby, message))
            mkxp_signalInfoDismissed()
        }

        // MARK: Watchdog

        func startWatchdog() {
            // The fork publishes its own hang flag. Graphics.frame_count stops while Ruby is stuck; the fork's average
            // frame rate does not, since it keeps its last value until the next frame.
            var fps = FrameRateSampler(frames: UInt(bitPattern: Int(mkxp_getFrameCount())))
            let watchdog = NativeWatchdog(read: {
                NativeWatchdog.Reading(
                    terminated: mkxp_isEngineTerminated() != 0,
                    paused: mkxp_isPaused() || mkxp_isPauseRequested(),
                    hung: mkxp_isEngineHung() != 0,
                    framesPerSecond: fps.sample(UInt(bitPattern: Int(mkxp_getFrameCount())))
                )
            }, onStall: { [weak self] stalled in
                guard let self else { return }
                NativeWatchdog.report(
                    stalled, engine: "engine", category: .ruby, host: host, session: configuration?.sessionID, onFailure: onFailure
                )
            })
            watchdog.start()
            self.watchdog = watchdog
        }
    }
#endif
