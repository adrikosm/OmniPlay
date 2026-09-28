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
            // One engine boot may host several slots (the three Ruby lines); they are spent together.
            for sibling in slot.diesWith {
                states[sibling] = .spent
            }
        case .clean:
            switch slot.sessionsPerProcess {
            case .unlimited, .oneWithSoftRestart:
                // A clean stop of a soft-restart engine means it parked, ready for any game of its own.
                states[slot] = .fresh
            case .one:
                if states[slot] != .spent {
                    states[slot] = .boundTo(game)
                }
            }
        }
    }

    /// Restores a spent slot recorded earlier in this process boot (a crash mid-session must not hide the truth).
    public func markSpent(_ slot: SessionSlot) { states[slot] = .spent }

    /// Slots that need a process relaunch for *any* game.
    public var spentSlots: Set<SessionSlot> {
        Set(states.filter { $0.value == .spent }.map(\.key))
    }

    public var activeSlots: [SessionSlot: UUID] { active }
}
