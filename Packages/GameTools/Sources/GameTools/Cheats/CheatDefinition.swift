import Diagnostics
import Foundation
import RuntimeCore

/// A cheat as data: typed steps over the state bridge, with parameters, requirements and a warning. Every step runs
/// through `MutationEngine`, so a cheat is validated, capped by the engine and undone like any other change.
public struct CheatDefinition: Codable, Sendable, Identifiable, Hashable {
    public enum Category: String, Codable, Sendable, CaseIterable {
        case currency, items, party, progress, movement, battle, system
    }

    /// `live`: gone when the session ends unless the game saves the changed value itself. `persistsInSave`: sets a
    /// hidden flag the game stores in its saves (VX Ace's encounter switch), so it asks before applying.
    public enum Persistence: String, Codable, Sendable {
        case live, persistsInSave
    }

    /// A literal or a `$parameter` reference.
    public enum Slot: Codable, Sendable, Hashable {
        case int(Int)
        case bool(Bool)
        case string(String)

        public init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) {
                self = .bool(b)
            } else if let i = try? c.decode(Int.self) {
                self = .int(i)
            } else {
                self = try .string(c.decode(String.self))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case let .int(i): try c.encode(i)
            case let .bool(b): try c.encode(b)
            case let .string(s): try c.encode(s)
            }
        }

        var parameter: String? {
            if case let .string(s) = self, s.hasPrefix("$") {
                String(s.dropFirst())
            } else {
                nil
            }
        }

        func resolved(_ values: [String: Int]) -> Any? {
            if let parameter {
                return values[parameter]
            }
            switch self {
            case let .int(i): return i
            case let .bool(b): return b
            case let .string(s): return s
            }
        }
    }

    public var id: String
    public var name: String
    public var summary: String
    public var category: Category
    /// Capability names (`StateCapabilities.named`) the game's engine must have.
    public var requires: [String]
    public var parameters: [Parameter]
    public var steps: [Step]
    public var persistence: Persistence
    public var warning: String?
    /// A single on/off patch: shown as a switch that reflects the game's current state.
    public var isToggle: Bool { steps.count == 1 && steps[0].op == .toggle && parameters.isEmpty }

    /// The capabilities this cheat needs, or nil when it names one that does not exist.
    public var requiredCapabilities: StateCapabilities? {
        requires.reduce(StateCapabilities?.some([])) { sum, name in
            guard let sum, let cap = StateCapabilities.named[name] else { return nil }
            return sum.union(cap)
        }
    }

    /// The first thing wrong with this definition, for the loader.
    func problem() -> String? {
        if requiredCapabilities == nil {
            return "unknown capability in \(requires)"
        }
        if steps.isEmpty {
            return "no steps"
        }
        let keys = Set(parameters.map(\.key))
        for step in steps {
            let slots = Array(step.target.values) + (step.value.map { [$0] } ?? [])
            for name in slots.compactMap(\.parameter) where !keys.contains(name) && !(name == "actor" && step.forEach == .partyMember) {
                return "step uses $\(name), which is not a parameter"
            }
            var sample = Dictionary(uniqueKeysWithValues: parameters.map { ($0.key, $0.defaultValue ?? $0.min ?? 1) })
            sample["actor"] = sample["actor"] ?? 1
            guard let json = step.targetJSON(sample),
                  StateWire.target(from: json) != nil else { return "step target \(step.target) is not a state target" }
        }
        return nil
    }
}

public extension CheatDefinition {
    struct Parameter: Codable, Sendable, Hashable {
        public var key: String
        public var label: String
        public var kind: Kind
        public var min: Int?
        public var max: Int?
        public var defaultValue: Int?
    }

    /// One change: a target in StateWire's JSON with `$key` slots for parameters, an operation and a value.
    struct Step: Codable, Sendable, Hashable {
        public var target: [String: Slot]
        public var op: Operation
        public var value: Slot?
        public var forEach: ForEach?
    }
}

extension CheatDefinition.Step {
    func targetJSON(_ values: [String: Int]) -> [String: Any]? {
        var out: [String: Any] = [:]
        for (key, slot) in target {
            guard let value = slot.resolved(values) else { return nil }
            out[key] = value
        }
        return out
    }

    public func resolvedTarget(_ values: [String: Int]) -> StateTarget? {
        targetJSON(values).flatMap(StateWire.target(from:))
    }
}

extension StateCapabilities {
    /// The names the cheat catalog uses.
    static let named: [String: StateCapabilities] = [
        "variables": .variables, "switches": .switches, "gold": .gold, "inventory": .inventory, "party": .party,
        "actors": .actors, "systemFlags": .systemFlags, "position": .position, "patches": .patches,
    ]
}

/// The bundled catalog (`Resources/cheats.json`), checked entry by entry: a broken entry is skipped with a log line,
/// never loaded half-right.
public struct CheatCatalog: Sendable {
    public let version: Int
    public let cheats: [CheatDefinition]

    private struct File: Decodable {
        var version: Int
        var cheats: [CheatDefinition]
    }

    public static let bundled: CheatCatalog = load(Bundle.module.url(forResource: "cheats", withExtension: "json"))

    static func load(_ url: URL?) -> CheatCatalog {
        guard let url, let data = try? Data(contentsOf: url) else {
            OPLog.log(.runtime, .error, "cheat catalog missing")
            return CheatCatalog(version: 0, cheats: [])
        }
        do {
            let file = try JSONDecoder().decode(File.self, from: data)
            var seen = Set<String>()
            let valid = file.cheats.filter { cheat in
                if let problem = cheat.problem() ?? (seen.contains(cheat.id) ? "duplicate id" : nil) {
                    OPLog.log(.runtime, .error, "cheat \(cheat.id) skipped: \(problem)")
                    return false
                }
                seen.insert(cheat.id)
                return true
            }
            return CheatCatalog(version: file.version, cheats: valid)
        } catch {
            OPLog.log(.runtime, .error, "cheat catalog unreadable: \(error)")
            return CheatCatalog(version: 0, cheats: [])
        }
    }

    /// The cheats this engine can run.
    public func available(for capabilities: StateCapabilities) -> [CheatDefinition] {
        cheats.filter { $0.requiredCapabilities.map(capabilities.isSuperset) ?? false }
    }
}

/// Runs a cheat's steps in order through the mutation engine and reports what happened.
@MainActor
public enum CheatRunner {
    public struct Outcome: Sendable {
        public var results: [StateMutationResult]
        /// Undo steps this run added (changes that actually changed something).
        public var recorded: Int
        public var applied: Bool { !results.isEmpty && results.allSatisfy { $0.result != .rejected } }
        public var message: String? {
            results.first { $0.result == .rejected }?.validation.first?.message
                ?? results.first { $0.result == .partial }?.validation.first?.message
        }
    }

    public static func run(_ cheat: CheatDefinition, parameters: [String: Int], with tools: MutationEngine) async -> Outcome {
        let before = tools.records.count
        var results: [StateMutationResult] = []
        for step in cheat.steps {
            var rounds = [parameters]
            if step.forEach == .partyMember {
                rounds = await partyMembers(tools).map { parameters.merging(["actor": $0]) { _, new in new } }
            }
            for values in rounds {
                guard let target = step.resolvedTarget(values) else { continue }
                let operation: ToolOperation = switch step.op {
                case .toggle: .toggle
                case .add: .increment(by: step.value?.resolved(values) as? Int ?? 0)
                case .set: .setValue(value(step.value?.resolved(values)))
                }
                await results.append(tools.apply(operation, to: target))
            }
        }
        return Outcome(results: results, recorded: max(0, tools.records.count - before))
    }

    /// Undoes a cheat run: its steps, newest first.
    public static func undo(_ outcome: Outcome, with tools: MutationEngine) async {
        for _ in 0 ..< outcome.recorded {
            _ = await tools.undo()
        }
    }

    private static func value(_ any: Any?) -> StateValue {
        switch any {
        case let b as Bool: .bool(b)
        case let i as Int: .int(i)
        case let s as String: .string(s)
        default: .null
        }
    }

    /// Party members' actor ids, from the actors list (one entry per property per member).
    private static func partyMembers(_ tools: MutationEngine) async -> [Int] {
        guard let page = try? await tools.list(.actors, query: nil, page: StatePage(size: 200)) else { return [] }
        var ids: [Int] = []
        for entry in page.entries {
            if case let .actorProperty(id, _) = entry.target, !ids.contains(id) {
                ids.append(id)
            }
        }
        return ids
    }
}

public extension CheatDefinition.Parameter {
    enum Kind: String, Codable, Sendable {
        case amount, item, weapon, armor, actor, variable, `switch`
    }
}

extension CheatDefinition.Parameter {
    enum CodingKeys: String, CodingKey { case key, label, kind, min, max, defaultValue = "default" }
}

public extension CheatDefinition.Step {
    enum Operation: String, Codable, Sendable { case set, add, toggle }
    /// Repeat the step for every party member, filling `$actor`.
    enum ForEach: String, Codable, Sendable { case partyMember }
}
