import Foundation

// One vocabulary for game state across engines (MV/MZ, RGSS, Ren'Py, web storage). Each engine's bridge translates
// these requests into its own objects on its own thread; the Game Tools, cheats and editors only ever see this.

/// A place in a game's state.
public enum StateTarget: Codable, Sendable, Hashable {
    case variable(Int)
    case `switch`(Int)
    case selfSwitch(map: Int, event: Int, key: String)
    case gold
    case item(kind: ItemKind, id: Int)
    case partyMember(actorID: Int)
    case actorProperty(actorID: Int, ActorProperty)
    case systemFlag(SystemFlag)
    case playerPosition
    case renpyStore(name: String, path: [String])
    case renpyPersistent(path: [String])
    case webStorageKey(namespace: String, key: String)
    case custom(engineKey: String)

    public enum ItemKind: String, Codable, Sendable, Hashable, CaseIterable { case item, weapon, armor }

    public enum ActorProperty: Codable, Sendable, Hashable {
        case hp, mp, tp, level, exp, name, godMode
        case param(Int)
        case skill(Int)
    }

    public enum SystemFlag: String, Codable, Sendable, Hashable, CaseIterable { case saveEnabled, encounterEnabled, menuEnabled }
}

/// A value as the tools show and edit it. Engine objects that are not plain data are reported, never edited.
public indirect enum StateValue: Codable, Sendable, Hashable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case list([StateValue])
    case dict([String: StateValue])
    case engineObject(typeName: String, summary: String)
    case unsupported(reason: String)
    case null
}

/// Where a list comes from: the categories the tools page through.
public enum StateCategory: String, Codable, Sendable, Hashable, CaseIterable {
    case variables, switches, selfSwitches, items, weapons, armors, party, actors, system, store, persistent, labels, storage
}

public enum StateInspectionRequest: Codable, Sendable, Hashable {
    /// A page of one category, optionally filtered by name or id.
    case list(category: StateCategory, query: String?, page: StatePage)
    case get(StateTarget)
    /// Names from the game's data (variable and switch names, item names), for labels in the tools.
    case metadata
}

public struct StatePage: Codable, Sendable, Hashable {
    public static let defaultSize = 200
    public var offset: Int
    public var size: Int

    public init(offset: Int = 0, size: Int = StatePage.defaultSize) {
        self.offset = max(0, offset)
        self.size = min(max(1, size), 1000)
    }

    public var next: StatePage { StatePage(offset: offset + size, size: size) }
}

public struct StateEntry: Codable, Sendable, Hashable {
    public var target: StateTarget
    public var name: String
    public var category: StateCategory
    public var value: StateValue
    public var editable: Bool
    /// Written to disk by the game itself (persistent data), so a change outlives the session and gets a backup first.
    public var persistent: Bool

    public init(target: StateTarget, name: String, category: StateCategory, value: StateValue, editable: Bool, persistent: Bool) {
        (self.target, self.name, self.category, self.value, self.editable, self.persistent) = (
            target,
            name,
            category,
            value,
            editable,
            persistent
        )
    }
}

public struct StateInspectionResult: Codable, Sendable, Hashable {
    public var entries: [StateEntry]
    public var page: StatePage
    /// More entries follow this page.
    public var hasMore: Bool

    public init(entries: [StateEntry], page: StatePage, hasMore: Bool) {
        (self.entries, self.page, self.hasMore) = (entries, page, hasMore)
    }
}

public enum MutationOperation: Codable, Sendable, Hashable {
    case set
    case add
    case toggle
    /// Set the value and hold it: the engine puts it back every frame (or tick) until unfrozen or the session ends.
    case freeze
    /// Stop holding the target; its value stays where it is.
    case unfreeze
}

public struct StateMutation: Codable, Sendable, Hashable {
    public var target: StateTarget
    public var operation: MutationOperation
    public var requested: StateValue

    public init(target: StateTarget, operation: MutationOperation = .set, requested: StateValue) {
        (self.target, self.operation, self.requested) = (target, operation, requested)
    }
}

public struct ValidationIssue: Codable, Sendable, Hashable {
    public enum Severity: String, Codable, Sendable, Hashable { case warning, error }
    public var severity: Severity
    public var message: String

    public init(_ severity: Severity, _ message: String) {
        (self.severity, self.message) = (severity, message)
    }
}

public struct StateMutationResult: Codable, Sendable, Hashable {
    public enum Outcome: String, Codable, Sendable, Hashable { case applied, rejected, partial }

    public var target: StateTarget
    public var oldValue: StateValue
    public var requestedValue: StateValue
    /// What the game actually holds afterwards (clamped gold, a capped level).
    public var effectiveValue: StateValue
    public var validation: [ValidationIssue]
    public var result: Outcome
    public var reversible: Bool
    public var persistent: Bool

    public init(
        target: StateTarget,
        oldValue: StateValue,
        requestedValue: StateValue,
        effectiveValue: StateValue,
        validation: [ValidationIssue] = [],
        result: Outcome,
        reversible: Bool = true,
        persistent: Bool = false
    ) {
        (self.target, self.oldValue, self.requestedValue, self.effectiveValue) = (target, oldValue, requestedValue, effectiveValue)
        (self.validation, self.result, self.reversible, self.persistent) = (validation, result, reversible, persistent)
    }

    public static func rejected(_ mutation: StateMutation, _ reason: String) -> StateMutationResult {
        StateMutationResult(
            target: mutation.target,
            oldValue: .null,
            requestedValue: mutation.requested,
            effectiveValue: .null,
            validation: [ValidationIssue(.error, reason)],
            result: .rejected,
            reversible: false
        )
    }
}

/// What a runtime offers the tools: implemented by each engine's state bridge.
@MainActor
public protocol StateInspecting: AnyObject, Sendable {
    /// The kinds of state this engine has at all; the tools show and edit nothing else.
    var stateCapabilities: StateCapabilities { get }
    func inspect(_ request: StateInspectionRequest) async throws -> StateInspectionResult
    func mutate(_ mutation: StateMutation) async -> StateMutationResult
}

/// The kinds of state an engine's bridge can reach. RPG Maker has variables, inventory and a party; Ren'Py has stores,
/// persistent data and labels, and no generic inventory or party.
public struct StateCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let variables = StateCapabilities(rawValue: 1 << 0)
    public static let switches = StateCapabilities(rawValue: 1 << 1)
    public static let gold = StateCapabilities(rawValue: 1 << 2)
    public static let inventory = StateCapabilities(rawValue: 1 << 3)
    public static let party = StateCapabilities(rawValue: 1 << 4)
    public static let actors = StateCapabilities(rawValue: 1 << 5)
    public static let systemFlags = StateCapabilities(rawValue: 1 << 6)
    public static let position = StateCapabilities(rawValue: 1 << 7)
    public static let store = StateCapabilities(rawValue: 1 << 8)
    public static let persistent = StateCapabilities(rawValue: 1 << 9)
    public static let labels = StateCapabilities(rawValue: 1 << 10)
    /// The bridge's named behaviour patches (no encounters, no-clip, debug menu).
    public static let patches = StateCapabilities(rawValue: 1 << 11)
    /// The player's own script lines, run in the game (`ScriptConsole`).
    public static let console = StateCapabilities(rawValue: 1 << 12)
    /// A running game: values can be watched and frozen. An offline save editor has everything else, not this.
    public static let live = StateCapabilities(rawValue: 1 << 13)

    /// RPG Maker MV/MZ and XP/VX/Ace: the same database-driven game objects.
    /// The engine loads and writes its own save slots on request (SAVE-009): RGSS and Ren'Py, whose saves are not
    /// safe to rewrite from outside.
    public static let slots = StateCapabilities(rawValue: 1 << 14)
    public static let rpgMaker: StateCapabilities = [
        .variables,
        .switches,
        .gold,
        .inventory,
        .party,
        .actors,
        .systemFlags,
        .position,
        .patches,
        .live,
    ]
    public static let renpy: StateCapabilities = [.store, .persistent, .labels, .console, .live]

    /// The capability a target needs.
    public static func required(for target: StateTarget) -> StateCapabilities {
        switch target {
        case .variable: .variables
        case .switch, .selfSwitch: .switches
        case .gold: .gold
        case .item: .inventory
        case .partyMember: .party
        case .actorProperty(_, .godMode): [.actors, .patches]
        case .actorProperty: .actors
        case .systemFlag: .systemFlags
        case .playerPosition: .position
        case .renpyStore: .store
        case .renpyPersistent: .persistent
        case let .custom(key): key.hasPrefix(StateWire.patchPrefix) ? .patches : .labels
        case .webStorageKey: []
        }
    }

    /// The list categories this engine can page through, in the order the tools show them.
    public var categories: [StateCategory] {
        var out: [StateCategory] = []
        if contains(.variables) {
            out.append(.variables)
        }
        if contains(.switches) {
            out.append(.switches)
        }
        if contains(.inventory) {
            out += [.items, .weapons, .armors]
        }
        if contains(.party) {
            out.append(.party)
        }
        if contains(.actors) {
            out.append(.actors)
        }
        if contains(.gold) || contains(.systemFlags) || contains(.position) {
            out.append(.system)
        }
        if contains(.store) {
            out.append(.store)
        }
        if contains(.persistent) {
            out.append(.persistent)
        }
        if contains(.labels) {
            out.append(.labels)
        }
        return out
    }
}

/// An engine that runs the player's own script in the game, the way its developer console would (Ren'Py's Python).
/// Save slots through the engine itself (SAVE-009): load a slot into the running game, and write the running game
/// into a slot. `file` is the slot's file name in the game's save folder; the engine maps it to its own slot.
@MainActor
public protocol SlotEditing: AnyObject {
    func loadSlot(file: String) async throws
    func saveSlot(file: String) async throws
}

/// No undo: the pre-launch save snapshot is the way back.
@MainActor
public protocol ScriptConsole: AnyObject {
    /// Evaluates an expression (`execute` false) or runs statements; the reply is the result's text or the error.
    func runScript(_ code: String, execute: Bool) async throws -> ScriptResult
}

public struct ScriptResult: Sendable, Hashable {
    public var ok: Bool
    public var output: String

    public init(ok: Bool, output: String) {
        (self.ok, self.output) = (ok, output)
    }
}

public enum StateBridgeError: Error, Equatable, Sendable {
    /// The game has not reached a point where its state exists (title screen, loading).
    case notInGame
    case timedOut
    case engine(String)
}
