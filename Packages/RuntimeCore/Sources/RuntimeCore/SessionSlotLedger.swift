import Foundation
import GameCore

/// The coordinator's ledger of which one-shot engine copies are spent this process (§14.2).
/// UI contract: the library shows a "restart needed" badge *before* the user taps a game whose
/// slot is spent. The ledger never attempts a reset it cannot prove.
public actor SessionSlotLedger {
    public enum LaunchVerdict: Sendable, Equatable {
        case ready
        case slotBusy(activeGame: UUID)
        case restartRequired(SlotSpentReason)
    }

    public enum SlotSpentReason: Sendable, Equatable {
        /// The adapter reported `.slotSpent` or `.restartRequired` on teardown.
        case spentByTeardown
        /// A one-shot slot already hosted a different game; only that game may relaunch.
        case boundToOtherGame(UUID)
    }

    public enum LedgerError: Error, Equatable {
        case launchNotPermitted(LaunchVerdict)
    }

    private enum SlotState: Equatable {
        case fresh
        case boundTo(UUID)
        case spent
    }

    private var states: [SessionSlot: SlotState] = [:]
    private var active: [SessionSlot: UUID] = [:]

    public init() {}

    public func launchVerdict(for slot: SessionSlot, game: UUID) -> LaunchVerdict {
        if let activeGame = active[slot] {
            return .slotBusy(activeGame: activeGame)
        }
        switch states[slot] ?? .fresh {
        case .fresh:
            return .ready
        case .spent:
            return .restartRequired(.spentByTeardown)
        case let .boundTo(bound):
            return bound == game ? .ready : .restartRequired(.boundToOtherGame(bound))
        }
    }

    public func recordStart(of slot: SessionSlot, game: UUID) throws {
        let verdict = launchVerdict(for: slot, game: game)
        guard verdict == .ready else { throw LedgerError.launchNotPermitted(verdict) }
        active[slot] = game
    }

    public func recordStop(of slot: SessionSlot, game: UUID, verdict: TeardownVerdict) {
        active[slot] = nil
        switch verdict {
        case .slotSpent, .restartRequired:
            states[slot] = .spent
        case .clean:
            switch slot.sessionsPerProcess {
            case .unlimited:
                states[slot] = .fresh
            case .one, .oneWithSoftRestart: // soft restart is treated as one-shot until proven on device
                if states[slot] != .spent {
                    states[slot] = .boundTo(game)
                }
            }
        }
    }

    /// Slots that need a process relaunch for *any* game.
    public var spentSlots: Set<SessionSlot> {
        Set(states.filter { $0.value == .spent }.map(\.key))
    }

    public var activeSlots: [SessionSlot: UUID] { active }
}
