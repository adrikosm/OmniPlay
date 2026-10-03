import GameStore
import GameTools
import RuntimeCore
import SwiftUI

/// Cheats as plain grouped lists. Each row says what it does and carries a switch, an Apply button, or Set up,
/// which opens a small form beside the list (a character, a value, Apply). Every change reads back what the game
/// accepted and can be undone, here or in Variables.
struct CheatsView: View {
    let tools: MutationEngine
    let game: GameRecord
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var setup: CheatHeader?
    @State var roster: [RosterMember] = []
    @State var stats: [ActorStat] = []
    @State var rosterProblem: String?
    @State var readingRoster = false
    @State var revision = 0
    /// The last value each row saw, so God mode can say "2 of 4 on" without reading again.
    @State var known: [StateTarget: StateValue] = [:]
    @State var bulkWorking = false
    @State var catalogWorking = false
    @State var messages: [String: String] = [:]
    @State var failed: Set<String> = []
    @State var lastRun: (name: String, records: [UUID])?
    @State var undoProblem: String?
    @State var undoing = false
    @State var pendingWarning: (cheat: CheatDefinition, parameters: [String: Int])?

    @Wide var wide

    var catalog: [CheatDefinition] {
        CheatCatalog.bundled.available(for: tools.capabilities)
            // Per-character God mode covers the party-wide catalogue switch.
            .filter { !($0.id == "battle.godMode" && stats.contains(.godMode)) }
    }

    var headers: [CheatHeader] {
        var result = stats.map(CheatHeader.actor)
        if tools.capabilities.contains(.gold) {
            result.append(.gold)
        }
        result += catalog.filter { !(tools.capabilities.contains(.gold) && $0.category == .currency) }.map(CheatHeader.catalog)
        return result
    }

    var body: some View {
        let groups = CheatHeader.Group.allCases.map { group in (group, headers.filter { $0.group == group }) }.filter { !$0.1.isEmpty }
        ScrollView {
            Group {
                if headers.isEmpty {
                    if readingRoster {
                        ProgressView("Reading the party…").frame(maxWidth: .infinity).padding(.top, Theme.s8)
                    } else {
                        ContentUnavailableView(
                            "No cheats available", systemImage: "sparkle",
                            description: Text("This game's engine does not expose values cheats can change.")
                        )
                    }
                } else if wide {
                    HStack(alignment: .top, spacing: Theme.s6) {
                        if let setup {
                            lists(groups).frame(maxWidth: 440)
                            form(setup)
                                .frame(maxWidth: 320)
                                .id(setup)
                                .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                        } else {
                            // Nothing being set up: the groups share both columns.
                            let half = (groups.count + 1) / 2
                            lists(Array(groups.prefix(half)))
                            lists(Array(groups.dropFirst(half)))
                        }
                    }
                } else {
                    lists(groups)
                }
            }
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s3)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollBounceBehavior(.basedOnSize)
        .canvas()
        .navigationTitle("Cheats")
        .navigationBarTitleDisplayMode(.inline)
        .task { await readRoster() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    revision += 1
                    Task { await readRoster() }
                }
                .symbolEffect(.rotate, value: revision)
                .tint(Theme.textPrimary)
                .disabled(readingRoster)
                Button { Task { await undo() } } label: {
                    HStack(spacing: 6) { Image(systemName: "arrow.uturn.backward"); Text("Undo") }.font(.subheadline.weight(.semibold))
                }
                .tint(Theme.textPrimary)
                .disabled(tools.records.isEmpty || undoing)
                .accessibilityValue(lastRun?.name ?? "")
            }
        }
        .sensoryFeedback(.success, trigger: tools.records.count) { old, new in new < old }
        .centeredSheet(isPresented: Binding(get: { setup != nil && !wide }, set: {
            if !$0 {
                setup = nil
            }
        }), width: 380) { close in
            if let setup {
                formContent(setup, close: close)
            }
        }
        .confirmationDialog(
            pendingWarning?.cheat.name ?? "",
            isPresented: $pendingWarning.isPresent(),
            titleVisibility: .visible
        ) {
            Button("Continue") {
                guard let pending = pendingWarning else { return }
                UserDefaults.standard.set(true, forKey: warnedKey(pending.cheat))
                pendingWarning = nil
                Task { await perform(pending.cheat, parameters: pending.parameters) }
            }
        } message: {
            Text(pendingWarning?.cheat.warning ?? "")
        }
    }

    // MARK: Lists

    func lists(_ groups: [(CheatHeader.Group, [CheatHeader])]) -> some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            ForEach(Array(groups.enumerated()), id: \.element.0) { index, pair in
                GlassSection(pair.0.title) {
                    ForEach(pair.1) { row($0) }
                }
                .rise(index)
            }
            if let undoProblem {
                Text(undoProblem).font(.footnote).foregroundStyle(Theme.danger).padding(.horizontal, Theme.s4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Title, one line of what it does (or what just happened), and the control.
    func row(_ header: CheatHeader) -> some View {
        let message = header.catalogID.flatMap { messages[$0] }
        let isFailed = header.catalogID.map(failed.contains) ?? false
        return HStack(spacing: Theme.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(header.title).font(.subheadline).foregroundStyle(Theme.textPrimary)
                Text(message ?? summaryLine(header)).font(.footnote)
                    .foregroundStyle(isFailed ? Theme.danger : Theme.textSecondary)
                    .lineLimit(2)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: Theme.s2)
            trailing(header)
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s2)
        .frame(minHeight: 58)
        .background(setup == header ? Theme.fill : .clear)
        .animation(Theme.quick, value: message)
    }

    func summaryLine(_ header: CheatHeader) -> String {
        if case .actor(.godMode) = header, !roster.isEmpty {
            let on = roster.count { known[.actorProperty(actorID: $0.id, .godMode)] == .bool(true) }
            return "\(on) of \(roster.count) on · " + header.summary
        }
        return header.summary
    }

    @ViewBuilder func trailing(_ header: CheatHeader) -> some View {
        switch header {
        case let .catalog(cheat) where cheat.parameters.isEmpty && cheat.isToggle:
            CatalogSwitch(cheat: cheat, tools: tools, revision: revision, working: catalogWorking) { await run(cheat, parameters: [:]) }
        case let .catalog(cheat) where cheat.parameters.isEmpty:
            smallButton(catalogWorking ? "Applying…" : "Apply") { Task { await run(cheat, parameters: [:]) } }
                .disabled(catalogWorking)
        default:
            smallButton("Set up") {
                withAnimation(Theme.motion(Theme.sheet, reduce: reduceMotion)) { setup = setup == header ? nil : header }
            }
        }
    }

    func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(PillButtonStyle(kind: .secondary, height: 34))
            .frame(minHeight: 44)
    }

    // MARK: Form

    func form(_ header: CheatHeader) -> some View {
        formContent(header) { withAnimation(Theme.motion(Theme.sheet, reduce: reduceMotion)) { setup = nil } }
            .padding(20)
            .glass(radius: 28, heavy: true)
    }

    func formContent(_ header: CheatHeader, close: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: header.formTitle, close: close)
            switch header {
            case let .actor(stat):
                if let rosterProblem {
                    problem(rosterProblem)
                } else if roster.isEmpty {
                    Text(readingRoster ? "Reading the party…" : "Nobody is in the party yet. Play past the first scene, then refresh.")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                } else if case .godMode = stat {
                    godMode
                } else {
                    ValueForm(stat: stat, roster: roster, tools: tools, known: $known) { lastRun = nil; undoProblem = nil }
                }
            case .gold:
                ValueForm(stat: nil, roster: [], tools: tools, known: $known) { lastRun = nil; undoProblem = nil }
            case let .catalog(cheat):
                CheatCatalogEditor(cheat: cheat, tools: tools, working: catalogWorking, revision: revision) { values in
                    await run(cheat, parameters: values)
                }
                .id(cheat.id)
                if let message = messages[cheat.id] {
                    Text(message).font(.footnote).foregroundStyle(failed.contains(cheat.id) ? Theme.danger : Theme.textSecondary)
                }
            }
            Text("You can undo this in Variables.")
                .font(.footnote).foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity)
        }
    }

    /// Everyone at once, then each character's own switch.
    @ViewBuilder var godMode: some View {
        let allOn = roster.allSatisfy { known[.actorProperty(actorID: $0.id, .godMode)] == .bool(true) }
        VStack(spacing: 0) {
            HStack {
                Text("Everyone").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Toggle("Everyone", isOn: Binding(get: { allOn }, set: { _ in Task { await bulkGodMode(on: !allOn) } }))
                    .labelsHidden().disabled(bulkWorking)
            }
            .padding(.horizontal, 14).frame(minHeight: 48)
            ForEach(roster) { member in
                let target = StateTarget.actorProperty(actorID: member.id, .godMode)
                Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, 14)
                CheatRow(
                    title: member.name, detail: nil, target: target, seed: known[target], tools: tools, revision: revision,
                    onValue: { known[target] = $0 }, onApplied: { lastRun = nil; undoProblem = nil }
                )
            }
        }
        .background(Theme.fill, in: .rect(cornerRadius: 14, style: .continuous))
    }

    func problem(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Text(text).font(.footnote).foregroundStyle(Theme.danger)
            Button("Read the party again") { Task { await readRoster() } }.buttonStyle(.link)
        }
    }

    func bulkGodMode(on: Bool) async {
        bulkWorking = true
        let before = Set(tools.records.map(\.id))
        for member in roster {
            let target = StateTarget.actorProperty(actorID: member.id, .godMode)
            let result = await tools.apply(.setValue(.bool(on)), to: target)
            if result.result != .rejected {
                known[target] = result.effectiveValue
            }
        }
        let added = tools.records.filter { !before.contains($0.id) }.map(\.id)
        if !added.isEmpty {
            lastRun = (on ? "God mode on for everyone" : "God mode off for everyone", added)
        }
        revision += 1
        bulkWorking = false
    }
}
