import CoreGraphics
import Diagnostics
import Foundation
import GameCore
import InputKit
import OverlayVFS
import SaveKit

/// The single adapter contract, generalised from three real adapters (Web, RGSS, Ren'Py); every member has a caller.
///
/// General rules:
/// 1. Adapters never touch the filesystem directly; all I/O goes through the overlay VFS layers they are given.
/// 2. Adapters never read raw touches; `InputKit` emits `GameInputEvent` (touch-native engines take SDL's own).
/// 3. `stop()` returns a verdict; `.slotSpent` is honest, not a failure.
/// 4. Engine-object access is marshalled onto the engine's thread; the adapter itself lives on the main actor.
/// 5. The slot is declared (`SessionSlot`), not discovered.
///
/// Rules for native engines that own a thread and open their own window (mkxp-z and Ren'Py so far; EasyRPG,
/// ScummVM and Godot next). Each was learned from a hang or a crash:
/// 6. The engine takes the main thread from a run-loop block, never a main-queue block: `EngineMainThread.run`.
/// 7. C callbacks the engine calls from its own thread are non-isolated top-level functions that hop to the main
///    actor. A closure written inside a `@MainActor` adapter inherits the isolation, and Swift 6 asserts on entry.
/// 8. Waits are against the clock (`ContinuousClock` deadlines), never counts of short sleeps: with an engine on
///    the main thread a sleep resumes when it resumes.
/// 9. The host overlay follows the picture. An engine window that becomes key draws above the app's, so the
///    adapter hands it to `RuntimeHost.adoptEngineWindow` and gives it back in `stop`; `showFrozenFrame` hides it
///    while the host's sheets are up.
@MainActor
public protocol GameRuntime: AnyObject, Sendable {
    func prepare(configuration: RuntimeConfiguration) async throws
    func start(in host: any RuntimeHost) async throws
    func pause() async
    func resume() async
    func send(_ input: GameInputEvent)
    func handleMemoryPressure(_ level: MemoryPressureLevel)
    func stop(reason: RuntimeStopReason) async -> TeardownVerdict
}

public extension GameRuntime {
    /// Engines that read the controllers and the touch screen themselves ignore host input.
    func send(_: GameInputEvent) {}
    func handleMemoryPressure(_: MemoryPressureLevel) {}
}

/// Adapters whose engine can pace its own frame limiter faster than real time. A side protocol rather than a flag:
/// the coordinator asks by conformance, and a runtime that does not conform simply stays at 1x.
@MainActor
public protocol FastForwardCapable: AnyObject, Sendable {
    /// 1 when off, 2...9 while active.
    var fastForward: Int { get }
    func setFastForward(_ multiplier: Int)
    /// What the pause menu offers; multipliers unless the engine means something else by going faster.
    var speedChoices: SpeedChoices { get }
}

public extension FastForwardCapable {
    var speedChoices: SpeedChoices { .multipliers }
}

/// The pause menu's speed row: its title and each value with the label it shows.
public struct SpeedChoices: Sendable, Equatable {
    public struct Option: Sendable, Hashable {
        public let value: Int
        public let label: String
        public init(value: Int, label: String) {
            self.value = value
            self.label = label
        }
    }

    public let title: String
    public let options: [Option]

    public init(title: String, options: [Option]) {
        self.title = title
        self.options = options
    }

    public static let multipliers = SpeedChoices(title: "Speed", options: [1, 2, 4, 8].map { Option(value: $0, label: "\($0)x") })
}

/// Adapters that can draw their current picture on request. Native engines do not need this: they hand the host
/// a frozen frame when they pause, and the pause menu's screenshot takes that.
@MainActor
public protocol ScreenCapturing: AnyObject, Sendable {
    func captureScreen() async -> CGImage?
}

/// Adapters that hand over the text their dictionaries missed and show translations as they arrive (TRANS-006).
@MainActor
public protocol LiveTranslationHost: AnyObject, Sendable {
    var onMissedText: (@MainActor (String) -> Void)? { get set }
    func deliverTranslations(_ translations: [String: String])
}

/// Adapters whose engine has a menu of its own worth reaching from the pause sheet (ScummVM's save/load/options).
@MainActor
public protocol EngineMenuCapable: AnyObject, Sendable {
    /// The pause-sheet label, e.g. "ScummVM menu".
    var engineMenuTitle: String { get }
    /// Called after the session has resumed.
    func openEngineMenu()
}

/// Rule 6: how a native engine gets the main thread.
public enum EngineMainThread {
    /// Runs `engine` (the engine's own `main`) on the main thread and returns at once; `exited` follows on the main
    /// actor when it returns. The block is a run-loop block because libdispatch never drains the main queue
    /// re-entrantly: an engine started from `DispatchQueue.main.async` keeps drawing while every main-actor
    /// continuation in the app, the adapter's own `start` included, waits for the session to end. From a run-loop
    /// block, the engine's event pump spinning CFRunLoop keeps the host's UI and main-actor work alive.
    public static func run(_ engine: @escaping @Sendable () -> Int32, exited: @escaping @MainActor @Sendable (Int32) -> Void) {
        RunLoop.main.perform(inModes: [.common]) {
            let status = engine()
            MainActor.assumeIsolated { exited(status) }
        }
    }
}

/// Everything an adapter needs to boot one game: the overlay layers to read through, the host-owned
/// directories it may write, the compatibility profile and the entry point detection found.
public struct RuntimeConfiguration: Sendable {
    public var game: GameID
    public var descriptor: GameDescriptor
    public var layers: [OverlayLayer]
    public var indexURL: URL
    public var saveDirectory: URL
    public var persistentDirectory: URL
    public var cacheDirectory: URL
    public var logDirectory: URL
    public var profile: CompatibilityProfile
    public var entryPoint: String?
    public var sessionID: SessionID

    public init(
        game: GameID,
        descriptor: GameDescriptor,
        layers: [OverlayLayer],
        indexURL: URL,
        saveDirectory: URL,
        persistentDirectory: URL,
        cacheDirectory: URL,
        logDirectory: URL,
        profile: CompatibilityProfile,
        entryPoint: String?,
        sessionID: SessionID = .init()
    ) {
        self.game = game
        self.descriptor = descriptor
        self.layers = layers
        self.indexURL = indexURL
        self.saveDirectory = saveDirectory
        self.persistentDirectory = persistentDirectory
        self.cacheDirectory = cacheDirectory
        self.logDirectory = logDirectory
        self.profile = profile
        self.entryPoint = entryPoint
        self.sessionID = sessionID
    }

    /// Layers, directories and entry point for a game as the store and detection recorded them.
    public static func forGame(
        _ descriptor: GameDescriptor,
        paths: AppPaths,
        profile: CompatibilityProfile,
        sidecars enabledOverlays: [OverlaySublayer] = []
    ) -> RuntimeConfiguration {
        let id = descriptor.id
        // One id names both the session record and its log directory, so a leftover marker finds its record.
        let session = SessionID()
        return RuntimeConfiguration(
            game: id, descriptor: descriptor,
            layers: LayerSetBuilder.forGame(descriptor, paths: paths, enabledOverlays: enabledOverlays),
            indexURL: paths.game(id).appending(path: "index.sqlite"),
            saveDirectory: paths.path(for: .saveFile, game: id),
            persistentDirectory: paths.tier(.persistent, for: id),
            cacheDirectory: paths.tier(.runtimeCache, for: id),
            logDirectory: paths.logs(game: id, session: session.rawValue),
            profile: profile, entryPoint: descriptor.entryPoint, sessionID: session
        )
    }
}
