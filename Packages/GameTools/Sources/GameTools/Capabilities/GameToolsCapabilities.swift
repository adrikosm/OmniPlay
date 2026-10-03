import GameCore
import RuntimeCore

/// The parts of Game Tools, in the order the control centre lists them.
public enum ToolsSection: String, CaseIterable, Sendable, Identifiable, Hashable {
    case variables, cheats, renpyTools, mods, translations, saves, persistentData, controls, runtime, diagnostics

    public var id: String { rawValue }
}

/// What Game Tools can do for one game right now. Views read this and nothing else: no view asks which engine a
/// game uses (`Scripts/check-no-engine-checks-in-views.sh`).
public struct GameToolsCapabilities: Sendable, Equatable {
    public enum Availability: Sendable, Equatable {
        case available
        /// The game has this, but not at the moment; the reason says what to do.
        case unavailable(String)
    }

    public struct Entry: Sendable, Equatable, Identifiable {
        public let section: ToolsSection
        public let availability: Availability
        public var id: ToolsSection { section }
    }

    /// Shown sections. A section the game can never have is absent, not disabled.
    public var sections: [Entry] = []
    /// The kinds of live state the game's engine exposes, whether or not it is running now.
    public var state: StateCapabilities = []

    /// The console needs the game running.
    public var canUseRenPyConsole: Bool { availability(of: .renpyTools) != nil && running && state.contains(.console) }
    /// This game's session is running now.
    public var running = false
    /// Lines no pack covers can be machine-translated on the device as they appear (TRANS-006; RPG Maker MV/MZ and Ren'Py).
    public var canLiveTranslate = false

    /// The list categories the variables editor offers, in order.
    public var variableCategories: [StateCategory] { state.categories }

    public func availability(of section: ToolsSection) -> Availability? {
        sections.first { $0.section == section }?.availability
    }
}

public enum GameToolsCapabilityResolver {
    public enum Session: Sendable, Equatable {
        case notRunning
        /// This game is running; `state` is what its runtime's bridge reports.
        case running(state: StateCapabilities)
    }

    /// What an engine family's state bridge exposes once running.
    public static func expectedState(for engine: EngineFamily) -> StateCapabilities {
        switch engine {
        case .rpgMakerMV, .rpgMakerMZ, .rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce: .rpgMaker
        case .renpy: .renpy
        default: []
        }
    }

    /// `hasPersistentData`: the game's save strategy names persistent stores (settings, global data, Ren'Py persistent).
    public static func resolve(
        engine: EngineFamily,
        playable: Bool,
        hasPersistentData: Bool = false,
        session: Session
    ) -> GameToolsCapabilities {
        var out = GameToolsCapabilities()
        let running: Bool
        switch session {
        case .notRunning:
            out.state = expectedState(for: engine)
            running = false
        case let .running(state):
            out.state = state
            running = true
        }
        out.running = running
        out.canLiveTranslate = [.rpgMakerMV, .rpgMakerMZ, .renpy].contains(engine)
        var entries: [GameToolsCapabilities.Entry] = []
        func add(_ section: ToolsSection, _ availability: GameToolsCapabilities.Availability) {
            entries.append(.init(section: section, availability: availability))
        }
        if playable, !out.state.isEmpty {
            add(.variables, running ? .available : .unavailable("Start the game to inspect live values."))
        }
        // The generic catalog is written against RPG Maker's objects; Ren'Py games have no gold or inventory.
        if playable, out.state.isSuperset(of: [.gold, .inventory, .actors]) {
            add(.cheats, running ? .available : .unavailable("Start the game to use cheats."))
        }
        if playable, out.state.contains(.console) {
            add(.renpyTools, .available)
        }
        // Mods need an engine whose files OmniPlay can layer: the RPG Maker families and Ren'Py.
        if playable, !expectedState(for: engine).isEmpty {
            add(.mods, .available)
            add(.translations, .available)
        }
        if playable, hasPersistentData {
            add(.persistentData, .available)
        }
        if playable {
            // While playing, only an engine that loads and writes its own slots offers them (edit in game, SAVE-009).
            if running {
                add(.saves, out.state.contains(.slots) ? .available : .unavailable("Leave the game to restore, import or export saves."))
            } else {
                add(.saves, .available)
            }
        }
        // Controller keys and the touch layout matter where OmniPlay turns input into keys; Ren'Py, ScummVM and Godot
        // read controllers and touches themselves.
        if playable, ![.renpy, .scummvm, .godot].contains(engine) {
            add(.controls, .available)
        }
        add(.runtime, .available)
        add(.diagnostics, .available)
        out.sections = entries
        return out
    }
}
