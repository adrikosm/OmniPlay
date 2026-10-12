import GameCore
import GameTools
import RuntimeCore
import SwiftUI

/// The running game's live values, by category: search by name, number or value, edit by type, watch, freeze, reset
/// and undo. One column by default so long names read in full; two in landscape when the player asks. A tap on a
/// name opens the whole value. Every change goes through `MutationEngine`; engine objects are shown and never edited.
struct VariablesView: View {
    let tools: MutationEngine
    let categories: [StateCategory]
    /// A save open in the editor: changed values say what they were, and the count of changes sits by the search.
    var editingSave = false
    var title = "Variables"
    /// The live game whose saved values ("Your cheats") show above the list; none for saves and persistent data.
    var cheatsFor: GameID?
    @Environment(AppModel.self) private var model
    @State private var saved: [AppModel.CustomCheat] = []
    @State private var category: StateCategory?
    @State private var query = ""
    @State private var scope = SearchScope.all
    @State private var entries: [StateEntry] = []
    /// The whole category, read once a search starts, so a value search sees every entry and not one page.
    @State private var everything: (category: StateCategory, entries: [StateEntry])?
    @State private var page = StatePage(size: 60)
    @State private var hasMore = false
    @State private var loading = false
    @State private var problem: String?
    @State private var rowErrors: [StateTarget: String] = [:]
    @State private var opened: StateTarget?
    @AppStorage("omniplay.variables.columns") private var columns = 1
    @Environment(\.scenePhase) private var scenePhase

    @Wide private var wide

    enum SearchScope: String, CaseIterable {
        case all, name, value

        var title: String {
            switch self {
            case .all: "All"
            case .name: "Name"
            case .value: "Value"
            }
        }

        var prompt: String {
            switch self {
            case .all: "Name, number or value"
            case .name: "Name or number"
            case .value: "Value, like Married or 100"
            }
        }
    }

    private var twoColumns: Bool { wide && columns == 2 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s4) {
                controls.rise(0)
                if !saved.isEmpty {
                    savedCheats.rise(0)
                }
                if let problem {
                    banner(problem)
                }
                if entries.isEmpty, !loading, problem == nil {
                    Text(query.isEmpty ? "Nothing here in this game." : "No \(scope == .value ? "value" : "match") for “\(query)”.")
                        .font(.subheadline).foregroundStyle(Theme.textSecondary).padding(.vertical, Theme.s4)
                }
                ValueColumns(entries: entries, wide: twoColumns) { entry in
                    VariableRow(
                        entry: entry,
                        live: tools.watched[entry.target] ?? tools.frozen[entry.target],
                        tools: tools,
                        showsWas: editingSave,
                        error: rowErrors[entry.target],
                        fullNames: !twoColumns,
                        apply: { operation in await refresh(tools.apply(operation, to: entry.target)) },
                        save: cheatsFor == nil ? nil : { save(entry) },
                        open: { opened = entry.target }
                    )
                }
                .rise(1)
                if hasMore {
                    Button("Show more") { Task { await load(more: true) } }.buttonStyle(.link).frame(maxWidth: .infinity).disabled(loading)
                }
            }
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s3)
            .frame(maxWidth: twoColumns ? .infinity : 760)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .canvas()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if wide {
                    Button {
                        withAnimation(Theme.snap) { columns = twoColumns ? 1 : 2 }
                    } label: {
                        Image(systemName: twoColumns ? "rectangle.split.2x1" : "rectangle")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .tint(Theme.textPrimary)
                    .accessibilityLabel(twoColumns ? "Show one column" : "Show two columns")
                    .accessibilityHint("One column shows long names in full.")
                }
                Button {
                    Task {
                        if let result = await tools.undo() {
                            refresh(result)
                        }
                    }
                } label: {
                    HStack(spacing: 6) { Image(systemName: "arrow.uturn.backward"); Text("Undo") }.font(.subheadline.weight(.semibold))
                }
                .tint(Theme.textPrimary)
                .disabled(tools.records.isEmpty)
                .accessibilityValue(tools.records.last
                    .map { "\(name(of: $0.target)): \($0.before.shortText) to \($0.after.shortText)" } ?? "")
            }
        }
        .sensoryFeedback(.success, trigger: tools.records.count) { old, new in new < old }
        .task(id: TaskKey(category: category, query: query, scope: scope)) {
            // A short pause so typing does not send a request per keystroke; a newer query cancels this one.
            do { try await Task.sleep(for: .milliseconds(query.isEmpty ? 0 : 250)) } catch { return }
            await load(more: false)
        }
        .task(id: WatchKey(targets: Set(tools.watched.keys), active: scenePhase == .active)) {
            guard scenePhase == .active, !tools.watched.isEmpty else { return }
            while !Task.isCancelled {
                await tools.refreshWatches()
                let process = ProcessInfo.processInfo
                let reduced = process.isLowPowerModeEnabled || process.thermalState == .serious || process.thermalState == .critical
                do { try await Task.sleep(for: reduced ? .seconds(2) : MutationEngine.watchInterval) } catch { return }
            }
        }
        .onAppear {
            if category == nil {
                category = categories.first
            }
            if let cheatsFor {
                saved = model.customCheats(for: cheatsFor)
            }
        }
        .overlay {
            if loading, entries.isEmpty {
                ProgressView()
            }
        }
        .centeredSheet(isPresented: $opened.isPresent(), width: 520) { close in
            if let target = opened, let entry = entries.first(where: { $0.target == target }) {
                VariableDetail(
                    entry: entry,
                    live: tools.watched[target] ?? tools.frozen[target],
                    tools: tools,
                    error: rowErrors[target],
                    apply: { operation in await refresh(tools.apply(operation, to: target)) },
                    save: cheatsFor == nil ? nil : { save(entry) },
                    close: close
                )
            }
        }
    }

    private struct TaskKey: Equatable {
        let category: StateCategory?
        let query: String
        let scope: SearchScope
    }

    private struct WatchKey: Equatable {
        let targets: Set<StateTarget>
        let active: Bool
    }

    /// Search with its scope, then the categories: on one line in landscape, stacked in portrait.
    @ViewBuilder private var controls: some View {
        let bar = ScrollView(.horizontal) {
            GlassSegmentBar(
                items: categories.map { ($0, $0.title) },
                selection: Binding(get: { category ?? categories.first ?? .variables }, set: { category = $0 })
            )
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .fixedSize(horizontal: false, vertical: true)
        let search = HStack(spacing: Theme.s2) {
            SearchField(text: $query, prompt: scope.prompt)
            GlassSegmentBar(items: SearchScope.allCases.map { ($0, $0.title) }, selection: $scope)
                .fixedSize()
                .accessibilityLabel("Search in")
        }
        if wide {
            VStack(alignment: .leading, spacing: Theme.s3) {
                HStack(spacing: Theme.s3) {
                    search.frame(minWidth: 320)
                    if editingSave {
                        changeCount
                    }
                }
                bar
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.s3) {
                search
                if editingSave {
                    changeCount
                }
                bar
            }
        }
    }

    /// "2 changes": how many values differ from the save as it was opened.
    private var changeCount: some View {
        let count = Set(tools.records.map(\.target)).count
        return Text(count == 1 ? "1 change" : "\(count) changes")
            .font(.footnote.monospacedDigit()).foregroundStyle(Theme.textSecondary)
            .contentTransition(.numericText())
            .animation(Theme.snap, value: count)
            .fixedSize()
    }

    private func banner(_ text: String) -> some View {
        GlassSection {
            ListRow(icon: "exclamationmark.triangle", title: text) {
                Button("Try again") { Task { await load(more: false) } }.buttonStyle(.link)
            }
        }
    }

    /// One tap sets the saved value again; touch and hold to remove it.
    private var savedCheats: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Text("Your cheats").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            ScrollView(.horizontal) {
                HStack(spacing: Theme.s2) {
                    ForEach(saved) { cheat in
                        Button {
                            Task { await refresh(tools.apply(.setValue(cheat.value), to: cheat.target)) }
                        } label: {
                            Text("\(cheat.name) = \(cheat.value.shortText)").font(.subheadline).lineLimit(1)
                                .padding(.horizontal, Theme.s3).frame(minHeight: 44)
                        }
                        .buttonStyle(PillButtonStyle(kind: .secondary, height: 44))
                        .contextMenu {
                            Button("Remove", systemImage: "trash", role: .destructive) { remove(cheat) }
                        }
                        .accessibilityHint("Sets it again. Touch and hold to remove.")
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func save(_ entry: StateEntry) {
        guard let cheatsFor else { return }
        let value = tools.watched[entry.target] ?? tools.frozen[entry.target] ?? entries.first { $0.target == entry.target }?.value ?? entry
            .value
        saved.removeAll { $0.target == entry.target }
        saved.append(.init(name: entry.name.isEmpty ? entry.target.shortDescription : entry.name, target: entry.target, value: value))
        model.setCustomCheats(saved, for: cheatsFor)
    }

    private func remove(_ cheat: AppModel.CustomCheat) {
        guard let cheatsFor else { return }
        saved.removeAll { $0.id == cheat.id }
        model.setCustomCheats(saved, for: cheatsFor)
    }

    private func name(of target: StateTarget) -> String {
        entries.first { $0.target == target }?.name ?? target.shortDescription
    }

    /// No search: the category a page at a time. A search: the whole category once, filtered here, so names,
    /// numbers and values are all matched the same way in every engine.
    private func load(more: Bool) async {
        guard let category else { return }
        // "Show more" runs outside the view's task, so cancellation alone does not catch a category or query change.
        let asked = TaskKey(category: category, query: query, scope: scope)
        var current: Bool { !Task.isCancelled && asked == TaskKey(category: self.category, query: query, scope: scope) }
        loading = true
        defer {
            if current {
                loading = false
            }
        }
        do {
            if query.isEmpty {
                let next = more ? page.next : StatePage(size: page.size)
                let result = try await tools.list(category, query: nil, page: next)
                // The category or query changed while the game answered; the newer request owns the list.
                guard current else { return }
                entries = more ? entries + result.entries : result.entries
                page = next
                hasMore = result.hasMore
                everything = nil // the next search reads the game afresh
            } else {
                let all: [StateEntry] = if let cached = everything, cached.category == category {
                    cached.entries
                } else {
                    try await readAll(category)
                }
                guard current else { return }
                everything = (category, all)
                entries = all.filter { Self.matches($0, query: query, scope: scope) }
                hasMore = false
            }
            problem = nil
        } catch StateBridgeError.timedOut {
            guard current else { return }
            problem = "The game did not answer in time. Resume it for a moment, then try again."
        } catch StateBridgeError.notInGame {
            guard current else { return }
            entries = []
            problem = "The game has not reached its first scene yet."
        } catch {
            guard current else { return }
            problem = "This list is not available: \(error)"
        }
    }

    private func readAll(_ category: StateCategory) async throws -> [StateEntry] {
        var all: [StateEntry] = []
        var next = StatePage(size: 1000)
        while true {
            let result = try await tools.list(category, query: nil, page: next)
            all += result.entries
            guard result.hasMore, !Task.isCancelled else { return all }
            next = next.next
        }
    }

    /// A name or number contains the query; a text value contains it; a number or switch equals it.
    static func matches(_ entry: StateEntry, query: String, scope: SearchScope) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        let byName = entry.name.lowercased().contains(q) || entry.target.number.map { String($0) == q } == true
        let byValue: Bool = switch entry.value {
        case let .string(text): text.lowercased().contains(q)
        case let .int(n): String(n) == q.replacingOccurrences(of: ",", with: "")
        case let .double(d): Double(q) == d
        case let .bool(on): (on ? ["on", "true"] : ["off", "false"]).contains(q)
        default: entry.value.shortText.lowercased().contains(q)
        }
        switch scope {
        case .all: return byName || byValue
        case .name: return byName
        case .value: return byValue
        }
    }

    private func refresh(_ result: StateMutationResult) {
        if result.result == .rejected {
            rowErrors[result.target] = result.validation.first?.message ?? "The game refused the change."
            return
        }
        rowErrors[result.target] = result.validation.first?.message // a clamp says so
        if let i = entries.firstIndex(where: { $0.target == result.target }) {
            entries[i].value = result.effectiveValue
        }
        if let i = everything?.entries.firstIndex(where: { $0.target == result.target }) {
            everything?.entries[i].value = result.effectiveValue
        }
    }
}
