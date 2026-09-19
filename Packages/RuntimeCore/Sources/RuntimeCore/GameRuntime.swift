import Diagnostics
import Foundation
import GameCore
import InputKit
import OverlayVFS
import SaveKit

/// The single adapter contract. Rules, enforced by review:
/// 1. Adapters never touch the filesystem directly; all I/O goes through the overlay VFS layers they are given.
/// 2. Adapters never read raw touches; `InputKit` emits `GameInputEvent`.
/// 3. `stop()` returns a verdict; `.slotSpent` is honest, not a failure.
/// 4. Engine-object access is marshalled onto the engine's thread; the adapter itself lives on the main actor.
/// 5. The slot is declared, not discovered.
@MainActor
public protocol GameRuntime: AnyObject, Sendable {
    static var runtimeID: RuntimeIdentifier { get }
    var capabilities: RuntimeCapabilities { get }
    var renderSurface: RuntimeSurface { get }

    func prepare(configuration: RuntimeConfiguration) async throws
    func start(in host: any RuntimeHost) async throws
    func pause() async
    func resume() async
    func send(_ input: GameInputEvent)

    func inspect(_ request: StateInspectionRequest) async throws -> StateInspectionResult
    func mutate(_ operation: StateMutation) async throws -> StateMutationResult

    func saveSnapshot() async throws -> SaveSnapshot
    func handleMemoryPressure(_ level: MemoryPressureLevel)
    func handleThermalState(_ state: ProcessInfo.ThermalState)
    func stop(reason: RuntimeStopReason) async -> TeardownVerdict
}

public extension GameRuntime {
    static var slot: SessionSlot { runtimeID.slot }
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
        return RuntimeConfiguration(
            game: id, descriptor: descriptor,
            layers: LayerSetBuilder.forGame(descriptor, paths: paths, enabledOverlays: enabledOverlays),
            indexURL: paths.game(id).appending(path: "index.sqlite"),
            saveDirectory: paths.path(for: .saveFile, game: id),
            persistentDirectory: paths.tier(.persistent, for: id),
            cacheDirectory: paths.tier(.runtimeCache, for: id),
            logDirectory: paths.logs(game: id, session: UUID()),
            profile: profile, entryPoint: descriptor.entryPoint
        )
    }
}
