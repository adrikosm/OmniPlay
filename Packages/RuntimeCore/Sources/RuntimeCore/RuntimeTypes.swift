import Diagnostics
import Foundation
import GameCore
import GameStore

/// What `stop()` reports. `.slotSpent` is a first-class, honest outcome (§4.2 rule 3). The reason behind a
/// verdict goes to the session log where it happens; nothing downstream branches on it.
public enum TeardownVerdict: Sendable, Equatable {
    /// The engine can take another game now: a fresh instance per game (web), or a parked engine that restarts
    /// in place (Ren'Py).
    case clean
    /// The engine's one boot for this process is used up; its slot (and `diesWith` siblings) need a relaunch.
    case slotSpent
    /// The engine did not stop (hung, or its state is unknown); the app should relaunch before anything else.
    case restartRequired
}

public enum RuntimeStopReason: Sendable, Equatable {
    case userExit
    case switchingGame
    case memoryPressure
    case thermal
    case crash(detail: String)
    case hostBackground
    case hostShutdown
    case fallback
}

public enum RuntimeEvent: Sendable {
    case log(LogCategory, String)
    case gradeReached(PlayabilityGrade)
    case watchdogStalled(seconds: Double)
    /// A value the shell should persist into the game's compatibility overrides for the next launch (e.g. the loopback port).
    case profileHint(key: String, value: String)
    /// The engine ended the session by itself (the game's own Quit, or an error it could not show); the shell leaves.
    case ended(status: Int32)
}

/// What the app hands the coordinator: the record, the descriptor and the resolution already made for this game.
public struct LaunchRequest: Sendable {
    public let record: GameRecord
    public let descriptor: GameDescriptor
    public let resolution: RuntimeResolution
    public let configuration: RuntimeConfiguration

    public init(record: GameRecord, descriptor: GameDescriptor, resolution: RuntimeResolution, configuration: RuntimeConfiguration) {
        self.record = record
        self.descriptor = descriptor
        self.resolution = resolution
        self.configuration = configuration
    }
}

public struct ActiveSession: Sendable, Hashable {
    public let id: UUID
    public let gameID: GameID
    public let runtime: RuntimeIdentifier
    public let slot: SessionSlot
    public let startedAt: Date
}

public enum LaunchPreflight: Sendable, Equatable {
    case ok
    case slotBusy(activeGame: GameID)
    case slotSpent(SessionSlotLedger.SlotSpentReason)
    case notBuilt(RuntimeIdentifier)
    case noRuntime(String)
}

public enum CoordinatorError: Error, Sendable, Equatable {
    case busy
    case preflight(LaunchPreflight)
    case prepareFailed(String)
    case startFailed(String)
}

/// Builds an adapter for a runtime identifier. Registered by each adapter module; the coordinator never imports one.
public typealias RuntimeFactory = @MainActor @Sendable (RuntimeConfiguration) -> any GameRuntime
