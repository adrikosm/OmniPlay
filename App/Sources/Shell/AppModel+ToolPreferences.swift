import Diagnostics
import GameCore
import GameTools
import RuntimeCore
import SwiftUI

extension AppModel {
    // MARK: Ren'Py Tools

    /// A developer switch (`RenPyEngineLibrary.Session.switchNames`), applied at the game's next launch.
    func developerSwitch(_ name: String, for id: GameID) -> Bool { hint("renpy.\(name)", for: id) == "1" }

    func setDeveloperSwitch(_ name: String, _ on: Bool, for id: GameID) {
        remember(hint: "renpy.\(name)", value: on ? "1" : "", for: id)
    }

    /// Console lines kept per game in the overrides ledger: `history` (newest last, at most 200) or `favourites`.
    func consoleLines(_ list: String, for id: GameID) -> [String] {
        guard let json = (try? store?.overrides.get(game: id, key: "renpy.console.\(list)")).flatMap(\.self),
              let lines = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) else { return [] }
        return lines
    }

    func setConsoleLines(_ lines: [String], _ list: String, for id: GameID) {
        guard let data = try? JSONEncoder().encode(Array(lines.suffix(200))), let json = String(data: data, encoding: .utf8) else { return }
        try? store?.overrides.set(game: id, key: "renpy.console.\(list)", valueJson: json)
    }

    /// A value the player saved from Variables to set again with one tap (CHEAT-001's per-game custom cheats).
    struct CustomCheat: Codable, Hashable, Identifiable {
        var name: String
        var target: StateTarget
        var value: StateValue
        var id: StateTarget { target }
    }

    func customCheats(for id: GameID) -> [CustomCheat] {
        guard let json = (try? store?.overrides.get(game: id, key: "cheats.custom")).flatMap(\.self) else { return [] }
        return (try? JSONDecoder().decode([CustomCheat].self, from: Data(json.utf8))) ?? []
    }

    func setCustomCheats(_ cheats: [CustomCheat], for id: GameID) {
        guard let data = try? JSONEncoder().encode(cheats), let json = String(data: data, encoding: .utf8) else { return }
        try? store?.overrides.set(game: id, key: "cheats.custom", valueJson: json)
    }

    // MARK: Walking speed (RPG Maker MV/MZ, XP/VX/VX Ace)

    /// Steps above the game's own walking speed (each doubles it) the player picked for this game.
    func walkingSpeed(for id: GameID) -> Int {
        (try? store?.overrides.get(game: id, key: "cheats.moveSpeed")).flatMap(\.self).flatMap { Int($0) } ?? 0
    }

    /// Sets it in the running game and keeps it for this game's next sessions; nil without a running game.
    func setWalkingSpeed(_ steps: Int, for id: GameID) async -> StateMutationResult? {
        guard let tools else { return nil }
        let result = await tools.apply(.setValue(.int(steps)), to: StateWire.patch("moveSpeed"))
        if result.result != .rejected, case let .int(now) = result.effectiveValue {
            try? store?.overrides.set(game: id, key: "cheats.moveSpeed", valueJson: String(now))
        }
        return result
    }

    /// The bridges answer nothing on the title screen, so this waits for a started or loaded game, then sets the kept
    /// speed once, outside Undo. The bridge holds it through later loads and To Title for the rest of the session.
    func restoreWalkingSpeed(for id: GameID) {
        let steps = walkingSpeed(for: id)
        guard steps > 0, let engine = tools, engine.capabilities.contains(.patches) else { return }
        let target = StateWire.patch("moveSpeed")
        Task {
            var failures = 0
            while !Task.isCancelled, tools === engine {
                do {
                    _ = try await engine.inspector.inspect(.get(target))
                    let result = await engine.inspector.mutate(StateMutation(target: target, operation: .set, requested: .int(steps)))
                    OPLog.log(.runtime, .info, "walking speed kept for this game: +\(steps) \(result.result.rawValue)")
                    return
                } catch StateBridgeError.notInGame {
                    // The title screen: as long as it takes.
                } catch {
                    // A page still loading has no bridge yet; a minute of that is not a game that is starting.
                    failures += 1
                    guard failures < 30 else {
                        OPLog.log(.runtime, .info, "walking speed not set again: \(error)")
                        return
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// The speed row's segments: RPG Maker's own numbers (4 is the engines' normal) once the game's speed is known.
    static func walkingSpeeds(base: Int?) -> [(Int, String)] {
        guard let base else { return [(0, "Normal"), (1, "2×"), (2, "4×"), (3, "8×")] }
        return (0 ... 3).map { ($0, "\(base + $0)") }
    }
}
