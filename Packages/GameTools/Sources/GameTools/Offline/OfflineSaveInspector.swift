import Foundation
import GameCore
import RuntimeCore
import SaveKit

/// Names for an RPG Maker game's variables, switches and items, read from its own `data/` folder (`System.json`,
/// `Items.json`, `Weapons.json`, `Armors.json`), each file capped at 8 MiB.
public struct RPGMakerNames: Sendable {
    public var variables: [String] = []
    public var switches: [String] = []
    public var items: [String] = []
    public var weapons: [String] = []
    public var armors: [String] = []

    public init() {}

    /// `gameRoot` is the game's own folder; MV ships its data under `www/data` when deployed, MZ and MV projects
    /// under `data`.
    public static func load(gameRoot: URL) -> RPGMakerNames {
        let data = ["www/data", "data"].map { gameRoot.appending(path: $0, directoryHint: .isDirectory) }
            .first { FileManager.default.fileExists(atPath: $0.appending(path: "System.json").path(percentEncoded: false)) }
        guard let data else { return RPGMakerNames() }
        func json(_ name: String) -> Any? {
            let url = data.appending(path: name)
            guard let bytes = try? SmallFileGuard.read(url) else { return nil }
            return try? JSONSerialization.jsonObject(with: bytes)
        }
        func names(_ file: String) -> [String] {
            (json(file) as? [Any] ?? []).map { ($0 as? [String: Any])?["name"] as? String ?? "" }
        }
        var out = RPGMakerNames()
        if let system = json("System.json") as? [String: Any] {
            out.variables = system["variables"] as? [String] ?? []
            out.switches = system["switches"] as? [String] ?? []
        }
        out.items = names("Items.json")
        out.weapons = names("Weapons.json")
        out.armors = names("Armors.json")
        return out
    }
}

/// An MV/MZ save opened while the game is not running, behind the same interface as a live game's bridge, so the
/// Variables editor and `MutationEngine` (validation, undo) work on it unchanged. Changes stay in memory until the
/// Save Manager writes the document back through `SafePersistTransaction`. Caps are MV/MZ's defaults: gold
/// 99,999,999, 99 of each item.
@MainActor
public final class OfflineSaveInspector: StateInspecting {
    public let document: RPGMakerSaveDocument
    public let names: RPGMakerNames
    /// Something was changed since the save was opened.
    public private(set) var changed = false

    public static let maxGold = 99_999_999
    public static let maxItems = 99

    public init(document: RPGMakerSaveDocument, names: RPGMakerNames) {
        self.document = document
        self.names = names
    }

    /// No `.live`: nothing runs, so nothing can be watched or frozen.
    public var stateCapabilities: StateCapabilities { [.variables, .switches, .gold, .inventory] }

    public func inspect(_ request: StateInspectionRequest) async throws -> StateInspectionResult {
        switch request {
        case let .get(target):
            guard let value = read(target) else { throw StateBridgeError.engine("not in this save") }
            return StateInspectionResult(entries: [entry(target, value)], page: StatePage(), hasMore: false)
        case let .list(category, query, page):
            let all = entries(category).filter { entry in
                guard let q = query?.lowercased(), !q.isEmpty else { return true }
                return entry.name.lowercased().contains(q) || entry.target.idString == q
            }
            let slice = Array(all.dropFirst(page.offset).prefix(page.size))
            return StateInspectionResult(entries: slice, page: page, hasMore: page.offset + page.size < all.count)
        case .metadata:
            return StateInspectionResult(entries: [], page: StatePage(), hasMore: false)
        }
    }

    public func mutate(_ mutation: StateMutation) async -> StateMutationResult {
        guard [.set, .add, .toggle].contains(mutation.operation) else {
            return .rejected(mutation, "Freezing needs the game running.")
        }
        guard let old = read(mutation.target) else { return .rejected(mutation, "This save has no such value.") }
        var requested = mutation.requested
        switch (mutation.operation, old, requested) {
        case let (.add, .int(have), .int(delta)): requested = .int(have + delta)
        case let (.toggle, .bool(on), _): requested = .bool(!on)
        default: break
        }
        switch (mutation.target, requested) {
        case let (.variable(id), .int(n)): document.setVariable(id, n)
        case let (.variable(id), .string(s)): document.setVariable(id, s)
        case let (.switch(id), .bool(on)): document.setSwitch(id, on)
        case let (.gold, .int(n)): document.setGold(min(max(0, n), Self.maxGold))
        case let (.item(kind, id), .int(n)): document.setCount(kind.saveKind, id, min(max(0, n), Self.maxItems))
        default: return .rejected(mutation, "This value cannot be set to that.")
        }
        changed = true
        let effective = read(mutation.target) ?? .null
        let clamped = mutation.operation == .set && effective != requested
        return StateMutationResult(
            target: mutation.target, oldValue: old, requestedValue: mutation.requested, effectiveValue: effective,
            validation: clamped ? [ValidationIssue(.warning, "Kept within the game's limits.")] : [],
            result: clamped ? .partial : .applied
        )
    }

    // MARK: Reading

    private func read(_ target: StateTarget) -> StateValue? {
        switch target {
        case let .variable(id): StateWire.value(document.variable(id))
        case let .switch(id): .bool(document.switch(id))
        case .gold: .int(document.gold)
        case let .item(kind, id): .int(document.count(kind.saveKind, id))
        default: nil
        }
    }

    private func entry(_ target: StateTarget, _ value: StateValue) -> StateEntry {
        StateEntry(
            target: target,
            name: name(target),
            category: StateWire.category(of: target),
            value: value,
            editable: true,
            persistent: false
        )
    }

    private func name(_ target: StateTarget) -> String {
        func pick(_ list: [String], _ id: Int, _ fallback: String) -> String {
            list.indices.contains(id) && !list[id].trimmingCharacters(in: .whitespaces).isEmpty ? list[id] : "\(fallback) \(id)"
        }
        switch target {
        case let .variable(id): return pick(names.variables, id, "Variable")
        case let .switch(id): return pick(names.switches, id, "Switch")
        case .gold: return "Gold"
        case let .item(kind, id):
            switch kind {
            case .item: return pick(names.items, id, "Item")
            case .weapon: return pick(names.weapons, id, "Weapon")
            case .armor: return pick(names.armors, id, "Armor")
            }
        default: return ""
        }
    }

    private func entries(_ category: StateCategory) -> [StateEntry] {
        func numbered(_ list: [String], _ target: (Int) -> StateTarget) -> [StateEntry] {
            (1 ..< max(list.count, 1)).compactMap { id in read(target(id)).map { entry(target(id), $0) } }
        }
        func named(_ list: [String], _ target: (Int) -> StateTarget) -> [StateEntry] {
            numbered(list, target).filter { !$0.name.hasPrefix("Item ") && !$0.name.hasPrefix("Weapon ") && !$0.name.hasPrefix("Armor ") }
        }
        switch category {
        case .variables: return numbered(names.variables) { .variable($0) }
        case .switches: return numbered(names.switches) { .switch($0) }
        case .items: return named(names.items) { .item(kind: .item, id: $0) }
        case .weapons: return named(names.weapons) { .item(kind: .weapon, id: $0) }
        case .armors: return named(names.armors) { .item(kind: .armor, id: $0) }
        case .system: return [entry(.gold, .int(document.gold))]
        default: return []
        }
    }
}

extension StateTarget {
    var idString: String? {
        switch self {
        case let .variable(id), let .switch(id), let .item(_, id): String(id)
        default: nil
        }
    }
}

extension StateTarget.ItemKind {
    var saveKind: RPGMakerSaveDocument.ItemKind {
        switch self {
        case .item: .items
        case .weapon: .weapons
        case .armor: .armors
        }
    }
}
