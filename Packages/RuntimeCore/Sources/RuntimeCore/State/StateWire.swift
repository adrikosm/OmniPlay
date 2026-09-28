import Foundation

/// The plain-JSON protocol every state bridge speaks (`omniplay-state.js` for MV/MZ, `omniplay_bridge.rb` for RGSS):
/// requests `{op, category, query, offset, size}` / `{op, target}` / `{op, target, operation, value}`, targets
/// `{kind, id, prop, param, flag, ...}` (Ren'Py: `{kind: "store", store, path}`, `{kind: "persistent", path}`,
/// `{kind: "label", name}`), plain JSON values; replies `{entries, hasMore}`, `{old, effective, persistent}` or
/// `{error}` (`notInGame` for a game not started yet). An entry the engine cannot show as data carries `objectType`
/// and `summary` instead of a value. Translation to and from `StateModel` lives here once.
public enum StateWire {
    public static func target(_ t: StateTarget) -> [String: Any]? {
        switch t {
        case let .variable(id): ["kind": "variable", "id": id]
        case let .switch(id): ["kind": "switch", "id": id]
        case let .selfSwitch(map, event, key): ["kind": "selfSwitch", "map": map, "event": event, "key": key]
        case .gold: ["kind": "gold"]
        case let .item(kind, id): ["kind": kind.rawValue, "id": id]
        case let .partyMember(actorID): ["kind": "partyMember", "id": actorID]
        case let .actorProperty(actorID, property):
            switch property {
            case .hp: ["kind": "actor", "id": actorID, "prop": "hp"]
            case .mp: ["kind": "actor", "id": actorID, "prop": "mp"]
            case .tp: ["kind": "actor", "id": actorID, "prop": "tp"]
            case .level: ["kind": "actor", "id": actorID, "prop": "level"]
            case .exp: ["kind": "actor", "id": actorID, "prop": "exp"]
            case .name: ["kind": "actor", "id": actorID, "prop": "name"]
            case .godMode: ["kind": "actor", "id": actorID, "prop": "godMode"]
            case let .param(i): ["kind": "actor", "id": actorID, "prop": "param", "param": i]
            case let .skill(id): ["kind": "actor", "id": actorID, "prop": "skill", "param": id]
            }
        case let .systemFlag(flag): ["kind": "system", "flag": flag.rawValue]
        case .playerPosition: ["kind": "position"]
        case let .renpyStore(name, path): ["kind": "store", "store": name, "path": path]
        case let .renpyPersistent(path): ["kind": "persistent", "path": path]
        case let .custom(key) where key.hasPrefix(labelPrefix): ["kind": "label", "name": String(key.dropFirst(labelPrefix.count))]
        case let .custom(key) where key.hasPrefix(patchPrefix): ["kind": "patch", "name": String(key.dropFirst(patchPrefix.count))]
        case .webStorageKey, .custom: nil
        }
    }

    /// Ren'Py labels travel as `.custom("label:<name>")`: they are listed and read, never edited.
    static let labelPrefix = "label:"
    /// Named behaviour patches for the cheat catalog (`noEncounters`, `noclip`, `godMode`, `debugMenu`) travel as
    /// `.custom("patch:<name>")`: on/off values the bridge implements itself, never code from the host.
    public static let patchPrefix = "patch:"

    public static func patch(_ name: String) -> StateTarget { .custom(engineKey: patchPrefix + name) }

    public static func target(from json: [String: Any]) -> StateTarget? {
        let id = json["id"] as? Int ?? 0
        switch json["kind"] as? String {
        case "variable": return .variable(id)
        case "switch": return .switch(id)
        case "selfSwitch": return .selfSwitch(
                map: json["map"] as? Int ?? 0,
                event: json["event"] as? Int ?? 0,
                key: json["key"] as? String ?? "A"
            )
        case "gold": return .gold
        case "item", "weapon", "armor": return (json["kind"] as? String).flatMap(StateTarget.ItemKind.init(rawValue:)).map { .item(
                kind: $0,
                id: id
            ) }
        case "partyMember": return .partyMember(actorID: id)
        case "actor":
            let param = json["param"] as? Int ?? 0
            let property: StateTarget.ActorProperty? = switch json["prop"] as? String {
            case "hp": .hp
            case "mp": .mp
            case "tp": .tp
            case "level": .level
            case "exp": .exp
            case "name": .name
            case "godMode": .godMode
            case "param": .param(param)
            case "skill": .skill(param)
            default: nil
            }
            return property.map { .actorProperty(actorID: id, $0) }
        case "system": return (json["flag"] as? String).flatMap(StateTarget.SystemFlag.init(rawValue:)).map { .systemFlag($0) }
        case "position": return .playerPosition
        case "store": return (json["path"] as? [String]).map { .renpyStore(name: json["store"] as? String ?? "store", path: $0) }
        case "persistent": return (json["path"] as? [String]).map { .renpyPersistent(path: $0) }
        case "label": return (json["name"] as? String).map { .custom(engineKey: labelPrefix + $0) }
        case "patch": return (json["name"] as? String).map(patch)
        default: return nil
        }
    }

    public static func value(_ any: Any?) -> StateValue {
        switch any {
        case nil, is NSNull: return .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            let d = n.doubleValue
            return d == d.rounded() && abs(d) < 9e15 ? .int(Int(d)) : .double(d)
        case let s as String: return .string(s)
        case let a as [Any]: return .list(a.map(value))
        case let o as [String: Any]: return .dict(o.mapValues(value))
        default: return .unsupported(reason: "\(type(of: any!))")
        }
    }

    public static func json(_ v: StateValue) -> Any {
        switch v {
        case let .bool(b): b
        case let .int(i): i
        case let .double(d): d
        case let .string(s): s
        case let .list(l): l.map(json)
        case let .dict(d): d.mapValues(json)
        case .engineObject, .unsupported, .null: NSNull()
        }
    }

    public static func operation(_ op: MutationOperation) -> String {
        switch op {
        case .set, .freeze, .unfreeze: "set"
        case .add: "add"
        case .toggle: "toggle"
        }
    }

    public static func request(_ r: StateInspectionRequest) -> [String: Any]? {
        switch r {
        case let .list(category, query, page):
            ["op": "list", "category": category.rawValue, "query": query ?? "", "offset": page.offset, "size": page.size]
        case let .get(t): target(t).map { ["op": "get", "target": $0] }
        case .metadata: ["op": "metadata"]
        }
    }

    public static func category(of target: StateTarget) -> StateCategory {
        switch target {
        case .variable: .variables
        case .switch: .switches
        case .selfSwitch: .selfSwitches
        case let .item(kind, _): kind == .item ? .items : kind == .weapon ? .weapons : .armors
        case .partyMember: .party
        case .actorProperty: .actors
        case .gold, .systemFlag, .playerPosition: .system
        case .renpyStore: .store
        case .renpyPersistent: .persistent
        case let .custom(key) where key.hasPrefix(labelPrefix): .labels
        case let .custom(key) where key.hasPrefix(patchPrefix): .system
        case .webStorageKey, .custom: .storage
        }
    }

    /// `set` for set/add/toggle; `freeze` sets and holds (`{old, effective}` like a set); `unfreeze` releases (`{}`).
    public static func mutationRequest(_ mutation: StateMutation) -> [String: Any]? {
        target(mutation.target).map {
            switch mutation.operation {
            case .freeze: ["op": "freeze", "target": $0, "value": json(mutation.requested)]
            case .unfreeze: ["op": "unfreeze", "target": $0]
            default: ["op": "set", "target": $0, "operation": operation(mutation.operation), "value": json(mutation.requested)]
            }
        }
    }

    /// A reply's error, as the bridge error it means.
    public static func error(in reply: [String: Any]) -> StateBridgeError? {
        guard let error = reply["error"] as? String else { return nil }
        return error == "notInGame" ? .notInGame : .engine(error)
    }

    public static func inspectionResult(_ reply: [String: Any], for request: StateInspectionRequest) -> StateInspectionResult {
        let page: StatePage = if case let .list(_, _, page) = request {
            page
        } else {
            StatePage()
        }
        let entries = (reply["entries"] as? [[String: Any]] ?? []).compactMap { entry -> StateEntry? in
            guard let json = entry["target"] as? [String: Any], let target = target(from: json) else { return nil }
            let shown: StateValue = if let type = entry["objectType"] as? String {
                .engineObject(typeName: type, summary: entry["summary"] as? String ?? "")
            } else {
                value(entry["value"])
            }
            return StateEntry(
                target: target,
                name: entry["name"] as? String ?? "",
                category: category(of: target),
                value: shown,
                editable: entry["editable"] as? Bool ?? true,
                persistent: entry["persistent"] as? Bool ?? false
            )
        }
        return StateInspectionResult(entries: entries, page: page, hasMore: reply["hasMore"] as? Bool ?? false)
    }

    /// A `set` reply as a result; a value the game adjusted (clamped gold, a capped level) is `partial` with a warning.
    public static func mutationResult(_ reply: [String: Any], for mutation: StateMutation) -> StateMutationResult {
        let effective = value(reply["effective"]), requested = mutation.requested
        let sameBool = (requested == .bool(true) && effective == .int(1)) || (requested == .bool(false) && effective == .int(0))
        let clamped = [.set, .freeze].contains(mutation.operation) && effective != requested && !sameBool
        return StateMutationResult(
            target: mutation.target,
            oldValue: value(reply["old"]),
            requestedValue: requested,
            effectiveValue: effective,
            validation: clamped ? [ValidationIssue(.warning, "The game adjusted the value to its own limits.")] : [],
            result: clamped ? .partial : .applied,
            persistent: reply["persistent"] as? Bool ?? false
        )
    }
}
