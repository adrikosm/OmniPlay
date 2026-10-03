import GameStore
import GameTools
import RuntimeCore
import SwiftUI

/// Catalogue parameters remain data driven, with the game's names and the catalogue's numeric limits.
struct CheatCatalogEditor: View {
    let cheat: CheatDefinition
    let tools: MutationEngine
    let working: Bool
    let revision: Int
    let onApply: ([String: Int]) async -> Void
    @State private var values: [String: Int] = [:]
    @State private var drafts: [String: String] = [:]
    @State private var options: [String: [(id: Int, name: String)]] = [:]
    @State private var optionErrors: [String: String] = [:]
    @State private var current: StateValue?
    @State private var readProblem: String?
    @State private var pending = false

    private var complete: Bool { cheat.parameters.allSatisfy { values[$0.key] != nil } }
    private var target: StateTarget? { cheat.steps.first?.forEach == nil ? cheat.steps.first?.resolvedTarget(values) : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if cheat.steps.contains(where: { $0.forEach == .partyMember }) || cheat.id == "battle.godMode" {
                formRow("Applies to") { Text("Entire party").foregroundStyle(Theme.textSecondary) }
            }
            if cheat.persistence == .persistsInSave {
                Label("Kept in saves", systemImage: "externaldrive").font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            ForEach(cheat.parameters, id: \.key) { parameter in field(parameter) }
            if cheat.isToggle {
                if case let .bool(on) = current {
                    formRow(on ? "On" : "Off") {
                        Toggle(cheat.name, isOn: Binding(get: { on }, set: { _ in submit() })).labelsHidden()
                    }
                } else {
                    Text(readProblem ?? "Reading current state…").font(.footnote).foregroundStyle(Theme.textSecondary)
                }
            } else {
                if let current, current.isPlain {
                    formRow("Now") { Text(current.shortText).font(Theme.value).foregroundStyle(Theme.textSecondary) }
                }
                if let readProblem {
                    Text(readProblem).font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                Button(action: submit) {
                    Text(pending ? "Applying…" : "Apply").frame(maxWidth: .infinity)
                }
                .buttonStyle(.primary)
                .disabled(!complete)
            }
        }
        .disabled(working || pending)
        .task { await loadOptions() }
        .task(id: target) { await read() }
        .onChange(of: revision) { _, _ in Task { await read() } }
    }

    private func field(_ parameter: CheatDefinition.Parameter) -> some View {
        VStack(alignment: .leading, spacing: Theme.s1) {
            if parameter.kind == .amount {
                formRow(parameter.label) {
                    TextField(parameter.label, text: Binding(get: { drafts[parameter.key] ?? "" }, set: { text in
                        drafts[parameter.key] = text
                        let range = (parameter.min ?? 0) ... (parameter.max ?? 9_999_999)
                        values[parameter.key] = Int(text).flatMap { range.contains($0) ? $0 : nil }
                    }))
                    .keyboardType(.numbersAndPunctuation).font(Theme.value).foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 140, minHeight: 44)
                    .accessibilityLabel(parameter.label)
                }
                if values[parameter.key] == nil {
                    Text("Enter a whole number from \((parameter.min ?? 0).formatted()) to \((parameter.max ?? 9_999_999).formatted()).")
                        .font(.footnote).foregroundStyle(Theme.danger)
                }
            } else if let error = optionErrors[parameter.key] {
                Text(error).font(.footnote).foregroundStyle(Theme.danger)
                Button("Try again") { Task { await loadOptions() } }.buttonStyle(.link)
            } else if let list = options[parameter.key] {
                if list.isEmpty {
                    Text("This game has no \(parameter.label.lowercased()) entries.").font(.footnote).foregroundStyle(Theme.textSecondary)
                } else {
                    Menu {
                        Picker(parameter.label, selection: Binding(get: { values[parameter.key] }, set: { values[parameter.key] = $0 })) {
                            ForEach(list, id: \.id) { option in Text("\(option.name)  #\(option.id)").tag(Int?.some(option.id)) }
                        }
                    } label: {
                        formRow(parameter.label) {
                            HStack(spacing: Theme.s1) {
                                Text(values[parameter.key].flatMap { id in list.first { $0.id == id }?.name } ?? "Choose")
                                    .foregroundStyle(Theme.textSecondary).lineLimit(1)
                                Chevron()
                            }
                        }
                    }
                }
            } else {
                HStack(spacing: Theme.s2) {
                    ProgressView().controlSize(.small)
                    Text("Reading \(parameter.label.lowercased())…").font(.footnote).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func submit() {
        guard complete, !pending, !working else { return }
        pending = true
        Task {
            await onApply(values)
            await read()
            pending = false
        }
    }

    private func read() async {
        current = nil
        readProblem = nil
        guard let target else { return }
        do {
            let value = try await tools.read(target)
            guard !Task.isCancelled else { return }
            current = value
            if value == nil {
                readProblem = "This value is not available yet. Resume the game, then refresh."
            }
        } catch {
            guard !Task.isCancelled else { return }
            readProblem = "The game did not return a value. Resume it, then refresh."
        }
    }

    private func loadOptions() async {
        for parameter in cheat.parameters {
            if parameter.kind == .amount {
                if drafts[parameter.key] == nil {
                    let value = parameter.defaultValue ?? parameter.min ?? 0
                    values[parameter.key] = value
                    drafts[parameter.key] = String(value)
                }
                continue
            }
            guard let category = parameter.kind.category else { continue }
            do {
                var list: [(id: Int, name: String)] = []
                var page = StatePage(size: 1000)
                while !Task.isCancelled {
                    let result = try await tools.list(category, query: nil, page: page)
                    list += result.entries.compactMap { entry in entry.target.number.map { ($0, entry.name) } }
                    if !result.hasMore {
                        break
                    }
                    page = page.next
                }
                guard !Task.isCancelled else { return }
                options[parameter.key] = list
                optionErrors[parameter.key] = nil
            } catch {
                optionErrors[parameter.key] = "Could not read \(parameter.label.lowercased()) entries. Resume the game, then try again."
            }
        }
    }
}

extension CheatDefinition.Parameter.Kind {
    var category: StateCategory? {
        switch self {
        case .amount: nil
        case .item: .items
        case .weapon: .weapons
        case .armor: .armors
        case .actor: .party
        case .variable: .variables
        case .switch: .switches
        }
    }
}

/// A label and a control on the quiet fill the cheat forms' rows share.
@MainActor func formRow(_ label: String, @ViewBuilder trailing: () -> some View) -> some View {
    HStack {
        Text(label).font(.subheadline).foregroundStyle(Theme.textPrimary)
        Spacer(minLength: Theme.s2)
        trailing()
    }
    .padding(.horizontal, 14)
    .frame(minHeight: 48)
    .background(Theme.fill, in: .rect(cornerRadius: 14, style: .continuous))
}
