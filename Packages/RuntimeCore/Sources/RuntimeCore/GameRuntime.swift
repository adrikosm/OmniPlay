import Foundation
import GameCore
import InputKit
import SaveKit

/// The single adapter contract (design authority §4.2). Rules, enforced by review:
/// 1. Adapters never touch the filesystem directly — all I/O goes through the overlay VFS.
/// 2. Adapters never read raw touches — `InputKit` emits `GameInputEvent`.
/// 3. `stop()` returns a verdict; `.slotSpent` is honest, not a failure.
/// 4. Engine-object access is marshalled onto the engine's thread.
/// 5. `static slot` is declared, not discovered.
///
/// Generalise this protocol when the *second* adapter arrives, not before.
public protocol GameRuntime: AnyObject {
    static var slot: SessionSlot { get }
    var capabilities: RuntimeCapabilities { get }
    var renderSurface: RuntimeSurface { get }

    func prepare(game: GameDescriptor, configuration: RuntimeConfiguration) async throws
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
