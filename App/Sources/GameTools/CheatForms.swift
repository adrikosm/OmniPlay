import GameTools
import RuntimeCore
import SwiftUI

/// A catalogue cheat that is simply on or off: reads the game's state and flips it through the catalogue runner.
struct CatalogSwitch: View {
    let cheat: CheatDefinition
    let tools: MutationEngine
    let revision: Int
    let working: Bool
    let toggle: () async -> Void
    @State private var on: Bool?

    var body: some View {
        Group {
            if let on {
                Toggle(cheat.name, isOn: Binding(get: { on }, set: { _ in
                    Task {
                        await toggle()
                        await read()
                    }
                }))
                .labelsHidden()
                .disabled(working)
            } else {
                ProgressView().controlSize(.small).frame(width: 51)
            }
        }
        .task(id: revision) { await read() }
    }

    private func read() async {
        guard let target = cheat.steps.first?.resolvedTarget([:]) else { on = false; return }
        if case let .bool(value) = try? await tools.read(target) {
            on = value
        } else {
            on = false
        }
    }
}

/// Set one value: for a party stat, which character first; then a slider with the value in mono beside it (tap it
/// to type an exact figure), and Apply. Reads the current value whenever the character changes.
struct ValueForm: View {
    /// Nil for the party's gold.
    let stat: ActorStat?
    let roster: [RosterMember]
    let tools: MutationEngine
    @Binding var known: [StateTarget: StateValue]
    let onApplied: () -> Void
    @State private var member: RosterMember?
    @State private var value = 0.0
    @State private var draft = ""
    @State private var working = false
    @State private var note: String?
    @State private var failed = false
    @FocusState private var typing: Bool

    private var target: StateTarget? {
        guard let stat else { return .gold }
        return (member ?? roster.first).map { .actorProperty(actorID: $0.id, stat.property) }
    }

    private var range: ClosedRange<Double> {
        switch stat {
        case .level?: 1 ... 99
        case .tp?: 0 ... 100
        case .hp?, .mp?: 0 ... 9999
        default: 0 ... 9_999_999
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if stat != nil {
                Menu {
                    ForEach(roster) { character in Button(character.name) { member = character } }
                } label: {
                    HStack {
                        Text("Character").font(.subheadline).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text((member ?? roster.first)?.name ?? "").font(.subheadline).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        Chevron()
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48)
                    .background(Theme.fill, in: .rect(cornerRadius: 14, style: .continuous))
                }
            }
            HStack(spacing: 14) {
                Slider(value: $value, in: range, step: 1).tint(Theme.textPrimary).accessibilityLabel("Value")
                ZStack(alignment: .trailing) {
                    if typing {
                        TextField("Value", text: $draft)
                            .focused($typing)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .onSubmit(commit)
                            .onChange(of: typing) { _, now in
                                if !now {
                                    commit()
                                }
                            }
                    } else {
                        Button {
                            draft = String(Int(value))
                            typing = true
                        } label: {
                            Text(Int(value).formatted()).contentTransition(.numericText(value: value))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Type an exact value")
                    }
                }
                .font(Theme.value)
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 84, height: 44, alignment: .trailing)
            }
            Button {
                Task { await apply() }
            } label: {
                Text(working ? "Applying…" : "Apply").frame(maxWidth: .infinity)
            }
            .buttonStyle(.primary)
            .disabled(working || target == nil)
            if let note {
                Text(note).font(.footnote).foregroundStyle(failed ? Theme.danger : Theme.textSecondary)
            }
        }
        .task(id: target) { await read() }
        .animation(Theme.snap, value: value)
    }

    private func commit() {
        typing = false
        if let number = Int(draft.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")) {
            value = min(max(Double(number), range.lowerBound), range.upperBound)
        }
    }

    private func read() async {
        guard let target else { return }
        var current = known[target]
        if current == nil {
            current = await (try? tools.read(target)) ?? nil
        }
        if case let .int(number)? = current {
            value = min(max(Double(number), range.lowerBound), range.upperBound)
        }
    }

    private func apply() async {
        guard let target else { return }
        working = true
        defer { working = false }
        let result = await tools.apply(.setValue(.int(Int(value))), to: target)
        if result.result == .rejected {
            failed = true
            note = result.validation.first?.message ?? "The game refused the change."
        } else {
            failed = false
            known[target] = result.effectiveValue
            note = "The game now has \(result.effectiveValue.shortText)."
            onApplied()
        }
    }
}
