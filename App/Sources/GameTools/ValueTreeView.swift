import GameCore
import GameTools
import RuntimeCore
import SwiftUI

/// A list or a set of values, one level at a time, in the same layout as Variables. Children of a Ren'Py store or
/// persistent value are edited in place by path; anything else is shown as it is.
struct ValueTreeView: View {
    let title: String
    let target: StateTarget
    @State var value: StateValue
    let tools: MutationEngine
    @State private var error: String?
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var typeSize

    init(title: String, target: StateTarget, value: StateValue, tools: MutationEngine) {
        self.title = title
        self.target = target
        _value = State(initialValue: value)
        self.tools = tools
    }

    private var children: [StateEntry] {
        let pairs: [(key: String, value: StateValue)] = switch value {
        case let .list(items): items.enumerated().map { (String($0.offset), $0.element) }
        case let .dict(values): values.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        default: []
        }
        return pairs.map { child in
            let childTarget = target.child(child.key)
            return StateEntry(
                target: childTarget ?? target, name: child.key, category: .store, value: child.value,
                editable: childTarget != nil && child.value.isPlain, persistent: false
            )
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s3) {
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Theme.danger)
                }
                ValueColumns(
                    entries: children,
                    wide: Adaptive.wide(vertical: verticalSizeClass, horizontal: horizontalSizeClass, type: typeSize)
                ) { entry in
                    VariableRow(entry: entry, live: nil, tools: tools, error: nil) { operation in
                        let result = await tools.apply(operation, to: entry.target)
                        if result.result == .rejected {
                            error = result.validation.first?.message
                        } else if let refreshed = try? await tools.inspector.inspect(.get(target)).entries.first?.value {
                            value = refreshed
                            error = nil
                        }
                    }
                }
                .rise(0)
            }
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s3)
        }
        .canvas()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension StateCategory {
    var title: String {
        switch self {
        case .variables: "Variables"
        case .switches: "Switches"
        case .selfSwitches: "Self switches"
        case .items: "Items"
        case .weapons: "Weapons"
        case .armors: "Armor"
        case .party: "Party"
        case .actors: "Actors"
        case .system: "Gold & system"
        case .store: "Store"
        case .persistent: "Persistent"
        case .labels: "Labels"
        case .storage: "Storage"
        }
    }
}

extension StateTarget {
    /// The number players know a value by in RPG Maker's editor.
    var number: Int? {
        switch self {
        case let .variable(id), let .switch(id), let .item(_, id), let .partyMember(id): id
        case let .actorProperty(id, _): id
        default: nil
        }
    }

    var shortDescription: String {
        switch self {
        case let .variable(id): "Variable \(id)"
        case let .switch(id): "Switch \(id)"
        case .gold: "Gold"
        case let .item(kind, id): "\(kind.rawValue.capitalized) \(id)"
        case let .renpyStore(store, path): (store == "store" ? "" : store.replacingOccurrences(of: "store.", with: "") + ".") + path
            .joined(separator: ".")
        case let .renpyPersistent(path): "persistent." + path.joined(separator: ".")
        default: "Value"
        }
    }

    /// The target one level down, for values that can be edited by path.
    func child(_ key: String) -> StateTarget? {
        switch self {
        case let .renpyStore(name, path): .renpyStore(name: name, path: path + [key])
        case let .renpyPersistent(path): .renpyPersistent(path: path + [key])
        default: nil
        }
    }
}

extension StateValue {
    var shortText: String {
        switch self {
        case let .bool(b): b ? "On" : "Off"
        case let .int(i): i.formatted()
        case let .double(d): d.formatted()
        case let .string(s): "“\(s)”"
        case let .list(l): l.count == 1 ? "1 item" : "\(l.count) items"
        case let .dict(d): d.count == 1 ? "1 value" : "\(d.count) values"
        case let .engineObject(type, _): type
        case .unsupported: "Unsupported"
        case .null: "—"
        }
    }

    var isText: Bool {
        if case .string = self {
            true
        } else {
            false
        }
    }

    var isInt: Bool {
        if case .int = self {
            true
        } else {
            false
        }
    }

    var isPlain: Bool {
        switch self {
        case .bool, .int, .double, .string: true
        default: false
        }
    }

    /// Typed text as a value of this value's kind.
    func parse(_ text: String) -> StateValue? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch self {
        case .int: return Int(trimmed.replacingOccurrences(of: ",", with: "")).map(StateValue.int)
        case .double: return Double(trimmed).map(StateValue.double)
        case .string: return .string(text)
        default: return nil
        }
    }
}
