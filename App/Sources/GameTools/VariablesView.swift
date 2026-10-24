import GameCore
import GameDetection
import GameStore
import GameTools
import RuntimeCore
import SwiftUI

/// The running game's live values, by category, a page at a time: search by name, number or value (at any depth where
/// the engine can look inside its objects), edit by type, watch, freeze, reset and undo. One column by default so long names read in full;
/// two in landscape when the player asks. A tap on a
/// name opens the whole value. Every change goes through `MutationEngine`; engine objects are shown and never edited.
/// Find by change: remember a category's values, play, then list only what changed, went up, went down or equals a
/// number, and remember again to narrow down to the one value that holds the gold.
struct VariablesView: View {
    let tools: MutationEngine
    let categories: [StateCategory]
    /// A save open in the editor: changed values say what they were, and the count of changes sits by the search.
    var editingSave = false
    var title = "Variables"
    /// The live game whose saved values ("Your cheats") show above the list; none for saves and persistent data.
    var cheatsFor: GameID?
    /// The running game, for the link to its saved web storage; none where that link makes no sense.
    var storageFor: GameRecord?
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
    @State private var total: Int?
    @State private var loading = false
    @State private var problem: String?
    @State private var rowErrors: [StateTarget: String] = [:]
    @State private var opened: StateTarget?
    @State private var find = FindMode.changed
    @State private var equals = ""
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

    /// How a remembered value must have moved to stay in the list.
    enum FindMode: String, CaseIterable {
        case changed, up, down, equals

        var title: String {
            switch self {
            case .changed: "Changed"
            case .up: "Went up"
            case .down: "Went down"
            case .equals: "Equals…"
            }
        }

        func keeps(_ now: StateValue, was: StateValue, equals: Double?) -> Bool {
            switch self {
            case .changed: return now != was
            case .up, .down:
                guard let a = now.number, let b = was.number else { return false }
                return self == .up ? a > b : a < b
            case .equals: return equals != nil && now.number == equals
            }
        }
    }

    /// Up to this many values are remembered from one category.
    static let rememberLimit = 5000

    private var twoColumns: Bool { wide && columns == 2 }
    private var remembered: [StateTarget: StateValue]? { category.flatMap { tools.remembered[$0] } }
    /// Find by change is for a running game, not a save on the table.
    private var canRemember: Bool { tools.capabilities.contains(.live) && !editingSave }

    var body: some View {
        ScrollViewReader { proxy in ScrollView {
            VStack(alignment: .leading, spacing: Theme.s4) {
                controls.rise(0).id("top")
                if let remembered {
                    findBar(remembered.count).rise(0)
                }
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
                PageBar(page: page, hasMore: hasMore, total: total, loading: loading) { next in
                    page = next
                    proxy.scrollTo("top", anchor: .top)
                }
                if let game = storageFor,
                   SaveStrategy.forEngine(game.engine, generation: game.generation).persistentStores.contains(.webLocalStorage) {
                    GlassSection {
                        NavigationLink { PersistentDataView(game: game, running: true, tools: tools) } label: {
                            ListRow(icon: "internaldrive", title: "Saved data", subtitle: "Open web storage") { Chevron() }
                        }
                        .buttonStyle(.row)
                    }
                    .rise(2)
                }
            }
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s3)
            .frame(maxWidth: twoColumns ? .infinity : 760)
            .frame(maxWidth: .infinity)
        }
        .modifier(BackToTopPastEnd(proxy: proxy))
        }
        .scrollDismissesKeyboard(.interactively)
        .canvas()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if canRemember {
                    Button(remembered == nil ? "Remember values" : "Remember again") { Task { await remember() } }
                        .font(.subheadline.weight(.semibold))
                        .tint(Theme.textPrimary)
                        .disabled(loading || category == nil)
                        .accessibilityHint(remembered == nil
                            ? "Keeps every value in this list, so you can find the ones that change."
                            : "Keeps only the values listed now, to narrow the search.")
                }
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
        .task(id: taskKey) {
            // A short pause so typing does not send a request per keystroke; a newer query cancels this one.
            do { try await Task.sleep(for: .milliseconds((query.isEmpty && equals.isEmpty) || page.offset > 0 ? 0 : 250)) } catch { return }
            await load()
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
        let page: StatePage
        /// Find by change: how many are remembered (nil when none), the mode and the number for Equals.
        var remembered: Int?
        var find = FindMode.changed
        var equals = ""
    }

    private var taskKey: TaskKey {
        TaskKey(category: category, query: query, scope: scope, page: page, remembered: remembered?.count, find: find, equals: equals)
    }

    /// Changed · Went up · Went down · Equals…, the number for Equals, and how many of the remembered values match.
    private func findBar(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            ScrollView(.horizontal) {
                GlassSegmentBar(items: FindMode.allCases.map { ($0, $0.title) }, selection: $find).fixedSize()
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .accessibilityLabel("Show values that")
            if find == .equals {
                TextField("Number", text: $equals)
                    .keyboardType(.numbersAndPunctuation)
                    .font(Theme.value)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, Theme.s3)
                    .frame(maxWidth: 220, minHeight: 44)
                    .glass(radius: Theme.fieldRadius)
                    .accessibilityLabel("Equals this number")
                    .transition(.opacity)
            }
            HStack(spacing: Theme.s3) {
                Text("\((total ?? entries.count).formatted()) of \(count.formatted()) match")
                    .font(.footnote.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                    .contentTransition(.numericText())
                Spacer(minLength: Theme.s2)
                Button("Forget values") {
                    if let category {
                        tools.remembered[category] = nil
                    }
                }
                .buttonStyle(.link)
                .font(.footnote)
            }
        }
        .animation(Theme.snap, value: find)
    }

    /// The first time, every value in the category (up to `rememberLimit`); after that, only the ones listed now, so
    /// each round narrows the last.
    private func remember() async {
        guard let category else { return }
        do {
            let values = if let remembered {
                try await stillMatching(category, remembered)
            } else {
                try await readAll(category, limit: Self.rememberLimit)
            }
            tools.remembered[category] = Dictionary(values.map { ($0.target, $0.value) }) { first, _ in first }
            problem = nil
        } catch StateBridgeError.notInGame {
            problem = Self.notInGame
        } catch {
            problem = "The values could not be read: \(error)"
        }
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
                selection: Binding(get: { category ?? categories.first ?? .variables }, set: { category = $0; page = page.first })
            )
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .fixedSize(horizontal: false, vertical: true)
        let search = HStack(spacing: Theme.s2) {
            // A new search or category starts on its first page.
            SearchField(text: Binding(get: { query }, set: { query = $0; page = page.first }), prompt: scope.prompt)
            GlassSegmentBar(
                items: SearchScope.allCases.map { ($0, $0.title) },
                selection: Binding(get: { scope }, set: { scope = $0; page = page.first })
            )
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
                Button("Try again") { Task { await load() } }.buttonStyle(.link)
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

    /// No search: the category a page at a time. A search: the engine's own search at any depth where it has one
    /// (`.nested`); otherwise the whole category once, filtered here, so names, numbers and values are matched the same
    /// way in every engine, and shown a page at a time.
    private func load() async {
        guard let category else { return }
        let asked = taskKey
        var current: Bool { !Task.isCancelled && asked == taskKey }
        loading = true
        defer {
            if current {
                loading = false
            }
        }
        do {
            let result: StateInspectionResult
            if let remembered {
                let found = try await stillMatching(category, remembered)
                guard current else { return }
                result = StateInspectionResult(
                    entries: Array(found.dropFirst(page.offset).prefix(page.size)),
                    page: page,
                    hasMore: page.offset + page.size < found.count,
                    total: found.count
                )
                everything = nil
            } else if query.isEmpty {
                result = try await tools.list(category, query: nil, page: page)
                everything = nil // the next search reads the game afresh
            } else if tools.capabilities.contains(.nested) {
                let q = query.trimmingCharacters(in: .whitespaces)
                result = try await tools.inspector.inspect(.search(
                    category: category, query: q, names: scope != .value, values: scope != .name, page: page
                ))
            } else {
                let all: [StateEntry] = if let cached = everything, cached.category == category {
                    cached.entries
                } else {
                    try await readAll(category)
                }
                guard current else { return }
                everything = (category, all)
                let found = all.filter { Self.matches($0, query: query, scope: scope) }
                result = StateInspectionResult(
                    entries: Array(found.dropFirst(page.offset).prefix(page.size)),
                    page: page,
                    hasMore: page.offset + page.size < found.count,
                    total: found.count
                )
            }
            // The category, query or page changed while the game answered; the newer request owns the list.
            guard current else { return }
            entries = result.entries
            hasMore = result.hasMore
            total = result.total
            problem = nil
        } catch StateBridgeError.timedOut {
            guard current else { return }
            problem = "The game did not answer in time. Resume it for a moment, then try again."
        } catch StateBridgeError.notInGame {
            guard current else { return }
            entries = []
            problem = Self.notInGame
        } catch {
            guard current else { return }
            problem = "This list is not available: \(error)"
        }
    }

    /// Every value of the category that moved the way Find asks since it was remembered, read fresh from the game, not
    /// just the page on screen.
    private func stillMatching(_ category: StateCategory, _ remembered: [StateTarget: StateValue]) async throws -> [StateEntry] {
        let all = try await readAll(category, limit: Self.rememberLimit)
        let number = Double(equals.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ""))
        return all.filter { entry in
            remembered[entry.target].map { find.keeps(entry.value, was: $0, equals: number) } == true &&
                Self.matches(entry, query: query, scope: scope)
        }
    }

    /// Shown while the bridge answers `notInGame`: the title screen, or a game still loading.
    static let notInGame = "Start a new game or load a save first. Changes on the title screen are lost when the game starts."

    private func readAll(_ category: StateCategory, limit: Int = .max) async throws -> [StateEntry] {
        var all: [StateEntry] = []
        var next = StatePage(size: 1000)
        while true {
            let result = try await tools.list(category, query: nil, page: next)
            all += result.entries
            guard result.hasMore, all.count < limit, !Task.isCancelled else { return Array(all.prefix(limit)) }
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

private extension StateValue {
    /// A number's value, for Went up, Went down and Equals.
    var number: Double? {
        switch self {
        case let .int(n): Double(n)
        case let .double(d): d
        default: nil
        }
    }
}
