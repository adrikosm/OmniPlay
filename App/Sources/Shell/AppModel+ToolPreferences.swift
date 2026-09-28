import GameCore
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
}
