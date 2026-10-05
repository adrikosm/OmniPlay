import Diagnostics
import Foundation
import GameCore
import GameImport
import InputKit

/// Per-game virtual-controls layouts. A game imported from a JoiPlay `.jgp` brings its `gamepad.json`; the first time
/// the game plays, that is translated (INPUT-006) and kept as the game's layout, so it plays with the keys its package
/// chose. Without one, the built-in layouts apply.
extension AppModel {
    static let controlsLayoutKey = "controls.layout"
    static let controllerMapKey = "controls.controllerMap"

    /// The game's controller-to-key map (INPUT-007), RPG Maker's defaults until the player changes one.
    func controllerMapping(for id: GameID) -> InputMapping {
        (try? store?.overrides.get(game: id, key: Self.controllerMapKey)).flatMap(\.self)
            .flatMap { try? JSONDecoder().decode(InputMapping.self, from: Data($0.utf8)) } ?? .rpgMaker
    }

    func setControllerMapping(_ mapping: InputMapping?, for id: GameID) {
        let json = mapping.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        try? store?.overrides.set(game: id, key: Self.controllerMapKey, valueJson: json)
        activeCapture?.mapping = mapping ?? .rpgMaker
    }

    /// Nil is the built-in pad. A stored `""` is the player choosing it, so the package layout, and after it the
    /// layout shared by every game with `family`'s pad, apply only while the key is absent.
    func controlsLayouts(for id: GameID, family: String? = nil) -> ControlsLayoutSet? {
        guard let json = (try? store?.overrides.get(game: id, key: Self.controlsLayoutKey)).flatMap(\.self) else {
            return importPackageLayout(for: id) ?? family.flatMap(sharedControlsLayouts).map {
                var shared = $0
                shared.source = "shared"
                return shared
            }
        }
        return try? JSONDecoder().decode(ControlsLayoutSet.self, from: Data(json.utf8))
    }

    func setControlsLayouts(_ set: ControlsLayoutSet?, for id: GameID) {
        let json = set.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        try? store?.overrides.set(game: id, key: Self.controlsLayoutKey, valueJson: json)
    }

    /// "Use for all games like this": one layout per pad family (RPG Maker keys differ from keyboard games'), kept
    /// on this device for games without a layout of their own.
    func sharedControlsLayouts(family: String) -> ControlsLayoutSet? {
        UserDefaults.standard.data(forKey: "omniplay.controls.shared.\(family)").flatMap {
            try? JSONDecoder().decode(ControlsLayoutSet.self, from: $0)
        }
    }

    func setSharedControlsLayouts(_ set: ControlsLayoutSet, family: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(set), forKey: "omniplay.controls.shared.\(family)")
    }

    /// The layout a JoiPlay package shipped, translated and stored once.
    private func importPackageLayout(for id: GameID) -> ControlsLayoutSet? {
        let url = paths.game(id).appending(path: "sidecars.json")
        guard let data = try? Data(contentsOf: url),
              let sidecars = try? JSONDecoder().decode(ImportSidecars.self, from: data),
              let gamepad = sidecars.files.first(where: { $0.key.lowercased() == "gamepad.json" })?.value,
              let result = try? JoiPlayLayoutImporter.translate(Data(gamepad.utf8)) else { return nil }
        setControlsLayouts(result.layouts, for: id)
        OPLog.log(
            .ui,
            .info,
            "JoiPlay layout imported: \(result.layouts.landscape.buttons.map { "\($0.label)=\($0.keys.map(\.rawValue))" })"
        )
        for note in result.notes {
            OPLog.log(.ui, .default, "JoiPlay layout: \(note)")
        }
        return result.layouts
    }
}
