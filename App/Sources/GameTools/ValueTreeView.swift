import GameCore
import GameTools
import RuntimeCore
import SwiftUI

/// A list, a set of values or a game object, one level at a time and a page at a time, in the same layout as
/// Variables. Engines that list children themselves (`.nested`, Ren'Py) answer with every value inside, objects too,
/// and their plain values are edited in place by path; anything else is shown as it is.
struct ValueTreeView: View {
    let title: String
    let target: StateTarget
    @State var value: StateValue
    let tools: MutationEngine
    @State private var error: String?
    @State private var page = StatePage(size: 60)
    /// The bridge's page of children, for `.nested` engines.
    @State private var listed: StateInspectionResult?
    @State private var loading = false
    @Wide private var wide

    private var fromBridge: Bool { tools.capabilities.contains(.nested) && target.child("") != nil }

    /// Children read from the value itself, for engines without `.nested`.
    private var derived: [StateEntry] {
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

    private var shown: [StateEntry] {
        fromBridge ? listed?.entries ?? [] : Array(derived.dropFirst(page.offset).prefix(page.size))
    }

    private var hasMore: Bool { fromBridge ? listed?.hasMore ?? false : page.offset + page.size < derived.count }
    private var total: Int? { fromBridge ? listed?.total : derived.count }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.s3) {
                    Color.clear.frame(height: 0).id("top")
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(Theme.danger)
                    }
                    if shown.isEmpty, !loading {
                        Text("Nothing inside.").font(.subheadline).foregroundStyle(Theme.textSecondary).padding(.vertical, Theme.s4)
                    }
                    ValueColumns(entries: shown, wide: wide) { entry in
                        VariableRow(
                            entry: entry,
                            live: tools.watched[entry.target] ?? tools.frozen[entry.target],
                            tools: tools,
                            error: nil
                        ) { operation in
                            let result = await tools.apply(operation, to: entry.target)
                            if result.result == .rejected {
                                error = result.validation.first?.message
                            } else {
                                error = nil
                                await reload()
                            }
                        }
                    }
                    .rise(0)
                    PageBar(page: page, hasMore: hasMore, total: total, loading: loading) { next in
                        page = next
                        proxy.scrollTo("top", anchor: .top)
                    }
                }
                .padding(.horizontal, Theme.s4)
                .padding(.vertical, Theme.s3)
            }
            .modifier(BackToTopPastEnd(proxy: proxy))
        }
        .canvas()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if loading, shown.isEmpty {
                ProgressView()
            }
        }
        .task(id: page) { await reload() }
    }

    /// The current page again after a change: from the bridge, or the whole value for engines without children.
    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            if fromBridge {
                listed = try await tools.inspector.inspect(.children(of: target, page: page))
            } else if let refreshed = try await tools.inspector.inspect(.get(target)).entries.first?.value {
                value = refreshed
            }
        } catch StateBridgeError.timedOut {
            error = "The game did not answer in time. Resume it for a moment, then try again."
        } catch {
            self.error = "This value is not available: \(error)"
        }
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
        case .enemies: "Enemies"
        case .maps: "Maps"
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
        case let .scriptVariable(root, path): ([root] + path).joined(separator: ".")
        default: "Value"
        }
    }

    /// The target one level down, for values that can be edited by path.
    func child(_ key: String) -> StateTarget? {
        switch self {
        case let .renpyStore(name, path): .renpyStore(name: name, path: path + [key])
        case let .renpyPersistent(path): .renpyPersistent(path: path + [key])
        case let .scriptVariable(root, path): .scriptVariable(root: root, path: path + [key])
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
