import Foundation
import GameCore
import RuntimeCore
import Testing

@Suite("Session slot ledger")
struct SessionSlotLedgerTests {
    let gameA = UUID()
    let gameB = UUID()

    @Test("Web slot hosts unlimited games")
    func webUnlimited() async throws {
        let ledger = SessionSlotLedger()
        for game in [gameA, gameB, gameA] {
            try await ledger.recordStart(of: .web, game: game)
            await ledger.recordStop(of: .web, game: game, verdict: .clean)
        }
        #expect(await ledger.launchVerdict(for: .web, game: gameB) == .ready)
        #expect(await ledger.spentSlots.isEmpty)
    }

    @Test("A busy slot refuses a second concurrent launch")
    func busySlot() async throws {
        let ledger = SessionSlotLedger()
        try await ledger.recordStart(of: .ruby18, game: gameA)
        #expect(await ledger.launchVerdict(for: .ruby18, game: gameB) == .slotBusy(activeGame: gameA))
        await #expect(throws: SessionSlotLedger.LedgerError.self) {
            try await ledger.recordStart(of: .ruby18, game: gameB)
        }
    }

    @Test("One-shot slot allows same-game restart but binds against other games")
    func oneShotBinding() async throws {
        let ledger = SessionSlotLedger()
        try await ledger.recordStart(of: .ruby18, game: gameA)
        await ledger.recordStop(of: .ruby18, game: gameA, verdict: .clean)
        #expect(await ledger.launchVerdict(for: .ruby18, game: gameA) == .ready)
        #expect(await ledger.launchVerdict(for: .ruby18, game: gameB) == .restartRequired(.boundToOtherGame(gameA)))
        // A different Ruby is a different slot: three RGSS games per launch if on different Rubies.
        #expect(await ledger.launchVerdict(for: .ruby31, game: gameB) == .ready)
    }

    @Test("`.slotSpent` spends the slot for everyone, including the same game")
    func slotSpentVerdict() async throws {
        let ledger = SessionSlotLedger()
        try await ledger.recordStart(of: .renpy853, game: gameA)
        await ledger.recordStop(of: .renpy853, game: gameA, verdict: .slotSpent)
        #expect(await ledger.launchVerdict(for: .renpy853, game: gameA) == .restartRequired(.spentByTeardown))
        #expect(await ledger.spentSlots == [.renpy853])
    }

    @Test("Soft-restart slots are treated as one-shot until proven")
    func softRestartIsConservative() async throws {
        #expect(SessionSlot.renpy853.sessionsPerProcess == .oneWithSoftRestart)
        let ledger = SessionSlotLedger()
        try await ledger.recordStart(of: .renpy853, game: gameA)
        await ledger.recordStop(of: .renpy853, game: gameA, verdict: .clean)
        #expect(await ledger.launchVerdict(for: .renpy853, game: gameB) == .restartRequired(.boundToOtherGame(gameA)))
    }

    @Test("Every §14.2 slot is declared")
    func slotsDeclared() {
        let names = Set(SessionSlot.allCases.map(\.rawValue))
        #expect(names.isSuperset(of: [
            "web",
            "scummvm",
            "ruby18",
            "ruby19",
            "ruby31",
            "renpy853",
            "renpy837",
            "renpy787",
            "easyrpg",
            "godot47",
            "godot44",
            "love",
            "onscripter",
            "tic80",
        ]))
    }
}
