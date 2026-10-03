import GameStore
import GameTools
import RuntimeCore
import SwiftUI

struct RosterMember: Identifiable, Hashable {
    let id: Int
    let name: String
}

/// What a party member's row edits.
enum ActorStat: CaseIterable, Hashable {
    case godMode, hp, mp, tp, level, exp

    init?(_ property: StateTarget.ActorProperty) {
        switch property {
        case .hp: self = .hp
        case .mp: self = .mp
        case .tp: self = .tp
        case .level: self = .level
        case .exp: self = .exp
        default: return nil
        }
    }

    var property: StateTarget.ActorProperty {
        switch self {
        case .godMode: .godMode
        case .hp: .hp
        case .mp: .mp
        case .tp: .tp
        case .level: .level
        case .exp: .exp
        }
    }
}

enum CheatHeader: Identifiable, Hashable {
    case actor(ActorStat)
    case gold
    case catalog(CheatDefinition)

    enum Group: CaseIterable { case party, money, items, progress, battle, other
        var title: String {
            switch self {
            case .party: "Party"
            case .money: "Money"
            case .items: "Items"
            case .progress: "Progress"
            case .battle: "Battle"
            case .other: "More"
            }
        }
    }

    var id: String {
        switch self {
        case let .actor(stat): "actor.\(stat)"
        case .gold: "gold"
        case let .catalog(cheat): cheat.id
        }
    }

    var group: Group {
        switch self {
        case .actor: .party
        case .gold: .money
        case let .catalog(cheat):
            switch cheat.category {
            case .currency: .money
            case .items: .items
            case .progress: .progress
            case .battle, .party: .battle
            case .movement, .system: .other
            }
        }
    }

    var title: String {
        switch self {
        case .actor(.godMode): "God mode"
        case .actor(.hp): "HP"
        case .actor(.mp): "MP"
        case .actor(.tp): "TP"
        case .actor(.level): "Level"
        case .actor(.exp): "Experience"
        case .gold: "Gold"
        case let .catalog(cheat): cheat.name
        }
    }

    /// The catalogue id, where per-cheat messages are kept.
    var catalogID: String? {
        if case let .catalog(cheat) = self {
            cheat.id
        } else {
            nil
        }
    }

    var formTitle: String {
        switch self {
        case .actor(.level): "Set level"
        case .actor(.exp): "Set experience"
        case .actor(.godMode), .catalog: title
        case .actor: "Set \(title)"
        case .gold: "Set gold"
        }
    }

    var summary: String {
        switch self {
        case .actor(.godMode): "Nothing hurts them this session. Saves never keep it."
        case .actor(.hp): "Hit points, kept within each character's maximum."
        case .actor(.mp): "Current magic points, within each character's maximum."
        case .actor(.tp): "Tech points for skills that use them."
        case .actor(.level): "The game applies its own cap and learns skills as it would."
        case .actor(.exp): "Crossing a threshold levels the character up."
        case .gold: "The party's money."
        case let .catalog(cheat): cheat.summary
        }
    }

    var symbol: String {
        switch self {
        case .actor(.godMode): "shield.fill"
        case .actor(.hp): "heart.fill"
        case .actor(.mp): "sparkles"
        case .actor(.tp): "bolt.fill"
        case .actor(.level): "arrow.up.circle.fill"
        case .actor(.exp): "star.fill"
        case .gold: "dollarsign.circle.fill"
        case let .catalog(cheat):
            switch cheat.category {
            case .currency: "dollarsign.circle"
            case .items: "bag.fill"
            case .progress: "flag.fill"
            case .movement: "figure.walk"
            case .battle, .party: "burst.fill"
            case .system: "gearshape.fill"
            }
        }
    }
}

/// One character (or the party) and one value: a switch, or − value + with the value tappable to type. Keeps the
/// accepted value on screen while a change is on its way, and says why when the game refuses.
struct CheatRow: View {
    let title: String
    let detail: String?
    let target: StateTarget
    let seed: StateValue?
    let tools: MutationEngine
    let revision: Int
    let onValue: (StateValue) -> Void
    let onApplied: () -> Void
    @State private var value: StateValue?
    @State private var pending = false
    @State private var problem: String?
    @State private var draft = ""
    @State private var shakes = 0
    @State private var outcome = 0
    @FocusState private var typing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Theme.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).foregroundStyle(Theme.textPrimary).lineLimit(2)
                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                } else if let detail {
                    Text(detail).font(.footnote.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: Theme.s2)
            control
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .keyframeAnimator(initialValue: 0.0, trigger: shakes) { content, x in
            content.offset(x: reduceMotion ? 0 : x)
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(-6, duration: 0.06)
                LinearKeyframe(5, duration: 0.07)
                LinearKeyframe(-3, duration: 0.07)
                LinearKeyframe(0, duration: 0.08)
            }
        }
        .sensoryFeedback(.error, trigger: shakes)
        .sensoryFeedback(.success, trigger: outcome)
        .task(id: revision) { await read() }
        .onAppear {
            if value == nil, let seed {
                show(seed)
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        switch value {
        case let .bool(on)?:
            Toggle(title, isOn: Binding(get: { on }, set: { send(.setValue(.bool($0))) }))
                .labelsHidden()
                .disabled(pending)
                .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.6), trigger: on) { _, new in new }
        case let .int(number)?:
            HStack(spacing: Theme.s1) {
                stepButton("minus", delta: -1, label: "Decrease")
                ZStack {
                    if typing {
                        TextField("Value", text: $draft)
                            .focused($typing)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.center)
                            .onSubmit(commitDraft)
                    } else {
                        Button { draft = String(number); typing = true } label: {
                            Text(number.formatted())
                                .contentTransition(.numericText(value: Double(number)))
                                .lineLimit(1).minimumScaleFactor(0.6)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(title), \(number)")
                        .accessibilityHint("Type an exact value")
                    }
                }
                .font(Theme.value)
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 84)
                .opacity(pending ? 0.5 : 1)
                .overlay(alignment: .trailing) {
                    if pending {
                        ProgressView().controlSize(.small).padding(.trailing, Theme.s2)
                    }
                }
                stepButton("plus", delta: 1, label: "Increase")
            }
            .accessibilityElement(children: .contain)
            .accessibilityAdjustableAction { direction in
                send(.increment(by: direction == .increment ? 1 : -1))
            }
        case let other?:
            Text(other.shortText).font(.footnote).foregroundStyle(Theme.textSecondary)
        case nil:
            ProgressView().controlSize(.small).frame(minWidth: 44, minHeight: 44)
        }
    }

    private func stepButton(_ symbol: String, delta: Int, label: String) -> some View {
        Button { send(.increment(by: delta)) } label: {
            Image(systemName: symbol).font(.footnote.weight(.bold)).foregroundStyle(Theme.textPrimary)
                .frame(width: 30, height: 30).background(Theme.fill, in: .circle)
                .frame(width: 38, height: 44).contentShape(.rect)
        }
        .buttonStyle(PressButtonStyle(scale: 0.88))
        .buttonRepeatBehavior(.enabled)
        .sensoryFeedback(delta > 0 ? .increase : .decrease, trigger: outcome)
        .accessibilityLabel("\(label) \(title)")
    }

    private func commitDraft() {
        typing = false
        guard let number = Int(draft.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")) else {
            problem = "“\(draft)” is not a whole number."
            shakes += 1
            return
        }
        send(.setValue(.int(number)))
    }

    private func show(_ new: StateValue) {
        withAnimation(Theme.motion(Theme.snap, reduce: reduceMotion)) { value = new }
        onValue(new)
    }

    private func send(_ operation: ToolOperation) {
        guard !pending else { return }
        pending = true
        Task {
            let result = await tools.apply(operation, to: target)
            pending = false
            if result.result == .rejected {
                problem = result.validation.first?.message ?? "The game refused the change."
                shakes += 1
                if let value {
                    onValue(value)
                } // snap the rail back to what is really there
            } else {
                problem = nil
                show(result.effectiveValue)
                outcome += 1
                onApplied()
            }
        }
    }

    private func read() async {
        do {
            let result = try await tools.read(target)
            guard !Task.isCancelled else { return }
            if let result {
                show(result)
            } else if value == nil {
                problem = "No value yet. Resume the game, then refresh."
            }
        } catch {
            guard !Task.isCancelled, value == nil else { return }
            problem = "The game did not answer. Resume it, then refresh."
        }
    }
}
