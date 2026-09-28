import GameCore
import GameTools
import RuntimeCore
import SwiftUI

/// The running game's live values, by category: search by name or number, edit by type, watch, freeze, reset and
/// undo. Every change goes through `MutationEngine`; engine objects are shown and never edited.
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
    @State private var entries: [StateEntry] = []
    @State private var page = StatePage(size: 60)
    @State private var hasMore = false
    @State private var loading = false
    @State private var problem: String?
    @State private var rowErrors: [StateTarget: String] = [:]
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase

    private var wide: Bool { Adaptive.wide(vertical: verticalSizeClass, horizontal: horizontalSizeClass, type: typeSize) }

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
                    Text(query.isEmpty ? "Nothing here in this game." : "No match for “\(query)”.")
                        .font(.subheadline).foregroundStyle(Theme.textSecondary).padding(.vertical, Theme.s4)
                }
                ValueColumns(entries: entries, wide: wide) { entry in
                    VariableRow(
                        entry: entry,
                        live: tools.watched[entry.target] ?? tools.frozen[entry.target],
                        tools: tools,
                        showsWas: editingSave,
                        error: rowErrors[entry.target],
                        apply: { operation in await apply(operation, to: entry) },
                        save: cheatsFor == nil ? nil : { save(entry) }
                    )
                }
                .rise(1)
                if hasMore {
                    Button("Show more") { Task { await load(more: true) } }.buttonStyle(.link).frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s3)
        }
        .scrollDismissesKeyboard(.interactively)
        .canvas()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
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
        .task(id: TaskKey(category: category, query: query)) {
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
    }

    private struct TaskKey: Equatable {
        let category: StateCategory?
        let query: String
    }

    private struct WatchKey: Equatable {
        let targets: Set<StateTarget>
        let active: Bool
    }

    /// Search and the categories on one line in landscape, stacked in portrait.
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
        if wide {
            HStack(spacing: Theme.s3) {
                SearchField(text: $query, prompt: "Name or value").frame(minWidth: 220)
                if editingSave {
                    changeCount
                }
                bar.frame(maxWidth: 440).fixedSize(horizontal: categories.count <= 4, vertical: false)
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.s3) {
                HStack(spacing: Theme.s3) {
                    SearchField(text: $query, prompt: "Name or value")
                    if editingSave {
                        changeCount
                    }
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

    private func load(more: Bool) async {
        guard let category else { return }
        loading = true
        defer { loading = false }
        let next = more ? page.next : StatePage(size: page.size)
        do {
            let result = try await tools.list(category, query: query.isEmpty ? nil : query, page: next)
            // The category or query changed while the game answered; the newer request owns the list.
            guard !Task.isCancelled else { return }
            entries = more ? entries + result.entries : result.entries
            page = next
            hasMore = result.hasMore
            problem = nil
        } catch StateBridgeError.timedOut {
            problem = "The game did not answer in time. Resume it for a moment, then try again."
        } catch StateBridgeError.notInGame {
            entries = []
            problem = "The game has not reached its first scene yet."
        } catch {
            problem = "This list is not available: \(error)"
        }
    }

    private func apply(_ operation: ToolOperation, to entry: StateEntry) async {
        let result = await tools.apply(operation, to: entry.target)
        refresh(result)
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
    }
}
