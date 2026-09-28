import GameCore
import GameTools
import RuntimeCore
import SwiftUI

/// A glass search field: magnifying glass, the text, and a clear button while there is something to clear.
struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: Theme.s2) {
            Image(systemName: "magnifyingglass").font(.subheadline).foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
            TextField(prompt, text: $text)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary) }
                    .buttonStyle(.plain)
                    .frame(width: 32, height: 44)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Theme.s3)
        .frame(minHeight: 44)
        .glass(radius: Theme.fieldRadius)
    }
}

/// Values in one glass list, or split into two side by side in landscape.
struct ValueColumns<Row: View>: View {
    let entries: [StateEntry]
    let wide: Bool
    @ViewBuilder let row: (StateEntry) -> Row

    var body: some View {
        // Keyed by position and name: children of an uneditable value share their parent's target.
        let keyed = entries.enumerated().map { (id: "\($0.offset).\($0.element.name)", entry: $0.element) }
        if keyed.isEmpty {
            EmptyView()
        } else if wide, keyed.count > 1 {
            let half = (keyed.count + 1) / 2
            HStack(alignment: .top, spacing: Theme.s4) {
                GlassSection { ForEach(keyed[..<half], id: \.id) { row($0.entry) } }
                GlassSection { ForEach(keyed[half...], id: \.id) { row($0.entry) } }
            }
        } else {
            GlassSection { ForEach(keyed, id: \.id) { row($0.entry) } }
        }
    }
}

/// One value: its name in mono, a small status after it (Watching, Frozen), and the control for its type. Touch and
/// hold, or •••, for watch, freeze and reset. A changed value carries a small accent dot.
struct VariableRow: View {
    let entry: StateEntry
    /// The watched or frozen value, when newer than the list's.
    let live: StateValue?
    let tools: MutationEngine
    /// Changed values say what they were ("was 32"), for the save editor.
    var showsWas = false
    let error: String?
    let apply: (ToolOperation) async -> Void
    /// Saves the current value as one of the game's own cheats; nil where that makes no sense (save files).
    var save: (() -> Void)?
    @State private var draft = ""
    @State private var invalid: String?
    /// A change is on its way to the game; further edits wait for its answer.
    @State private var pending = false
    @State private var typing = false
    @FocusState private var editing: Bool

    private var value: StateValue { live ?? entry.value }
    private var frozen: Bool { tools.frozen[entry.target] != nil }
    private var watched: Bool { tools.watched[entry.target] != nil }
    private var initial: StateValue? { tools.initialValue(of: entry.target) }
    private var title: String { entry.name.isEmpty ? entry.target.shortDescription : entry.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.s2) {
                if initial != nil {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6).accessibilityLabel("Changed")
                }
                Text(title).font(.system(.subheadline, design: .monospaced)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    .truncationMode(.middle)
                status
                Spacer(minLength: Theme.s2)
                editor
                if entry.editable {
                    menu
                }
            }
            if let message = invalid ?? error {
                Text(message).font(.footnote).foregroundStyle(Theme.danger)
            }
        }
        .disabled(pending)
        .padding(.leading, Theme.s4)
        .padding(.trailing, entry.editable ? Theme.s1 : Theme.s4)
        .padding(.vertical, 4)
        .frame(minHeight: 52)
        .contentShape(.rect)
        .contextMenu {
            if entry.editable {
                menuItems.tint(Theme.textPrimary)
            }
        }
    }

    /// Frozen beats watching; the RPG Maker number and "kept on disk" fill in when nothing is going on.
    @ViewBuilder private var status: some View {
        let was = showsWas ? initial.map { "was \($0.shortText)" } : nil
        let label = was ??
            (frozen ? "Frozen" : watched ? "Watching" : entry.persistent ? "Kept on disk" : entry.target.number.map { "#\($0)" })
        if let label {
            Text(label).font(.footnote).foregroundStyle(Theme.textSecondary).lineLimit(1).fixedSize()
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch value {
        case let .bool(on) where entry.editable:
            Toggle(title, isOn: Binding(get: { on }, set: { new in send(.setValue(.bool(new))) }))
                .labelsHidden()
        case let .int(n) where entry.editable:
            HStack(spacing: 2) {
                stepButton("minus") { send(.increment(by: -1)) }
                valueField(n.formatted(), number: Double(n))
                stepButton("plus") { send(.increment(by: 1)) }
            }
        case .double where entry.editable, .string where entry.editable:
            valueField(value.shortText, number: nil)
        case let .engineObject(typeName, summary):
            VStack(alignment: .trailing, spacing: 2) {
                Text(typeName).font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                Text(summary).font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            .frame(maxWidth: 160, alignment: .trailing)
            .accessibilityLabel("\(typeName), read-only")
        case .list, .dict:
            NavigationLink { ValueTreeView(title: title, target: entry.target, value: value, tools: tools) } label: {
                HStack(spacing: Theme.s1) {
                    Text(value.shortText).font(.subheadline).foregroundStyle(Theme.textSecondary)
                    Chevron()
                }
                .frame(minHeight: 44)
            }
        default:
            Text(value.shortText).font(Theme.value).foregroundStyle(Theme.textSecondary)
        }
    }

    private func send(_ operation: ToolOperation) {
        pending = true
        Task {
            await apply(operation)
            pending = false
        }
    }

    /// − and +: small fill discs with a full 44 pt target, repeating while held.
    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.footnote.weight(.bold)).foregroundStyle(Theme.textPrimary)
                .frame(width: 30, height: 30).background(Theme.fill, in: .circle)
                .frame(width: 38, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(PressButtonStyle(scale: 0.88))
        .buttonRepeatBehavior(.enabled)
        .sensoryFeedback(symbol == "plus" ? .increase : .decrease, trigger: value)
        .accessibilityLabel(symbol == "plus" ? "Increase" : "Decrease")
    }

    /// The value as the game holds it, in mono; a tap turns it into a field for typing a new one.
    private func valueField(_ shown: String, number: Double?) -> some View {
        ZStack {
            if typing {
                TextField(shown, text: $draft)
                    .focused($editing)
                    .keyboardType(value.isText ? .default : .numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .submitLabel(.done)
                    .onAppear { editing = true }
                    .onChange(of: editing) { _, focused in
                        if !focused {
                            typing = false
                        }
                    }
                    .onSubmit {
                        // A typo stays in the field with a note, so it can be corrected rather than retyped.
                        guard let typed = value.parse(draft) else {
                            invalid = value.isText ? nil : "“\(draft)” is not a \(value.isInt ? "whole number" : "number")."
                            return
                        }
                        invalid = nil
                        typing = false
                        send(.setValue(typed))
                    }
                    .accessibilityLabel("New value for \(title)")
            } else {
                Button {
                    if case let .string(text) = value {
                        draft = text
                    } else {
                        draft = shown.replacingOccurrences(of: ",", with: "")
                    }
                    typing = true
                } label: {
                    Text(shown)
                        .contentTransition(number.map { .numericText(value: $0) } ?? .opacity)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: number == nil ? .trailing : .center)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), \(shown)")
                .accessibilityHint("Type a new value")
            }
        }
        .font(Theme.value)
        .foregroundStyle(number == nil ? Theme.textSecondary : Theme.textPrimary)
        .frame(minWidth: number == nil ? 60 : 52, maxWidth: value.isText ? 180 : 96)
        .animation(Theme.snap, value: shown)
    }

    private var menu: some View {
        Menu { menuItems } label: {
            Image(systemName: "ellipsis").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                .frame(width: 40, height: 44).contentShape(.rect)
        }
        .tint(Theme.textPrimary)
        .accessibilityLabel("More for \(title)")
    }

    @ViewBuilder private var menuItems: some View {
        if tools.capabilities.contains(.live) {
            Button(watched ? "Stop watching" : "Watch", systemImage: watched ? "eye.slash" : "eye") {
                if watched {
                    tools.unwatch(entry.target)
                } else {
                    tools.watch(entry.target)
                }
            }
        }
        if tools.capabilities.contains(.live), !entry.persistent, value.isPlain {
            Button(frozen ? "Unfreeze" : "Freeze at \(value.shortText)", systemImage: "snowflake") {
                Task {
                    if frozen {
                        await tools.unfreeze(entry.target)
                    } else {
                        await tools.freeze(entry.target, at: value)
                    }
                }
            }
        }
        if let save, value.isPlain {
            Button("Save as cheat (\(value.shortText))", systemImage: "star", action: save)
        }
        if let initial {
            Button("Reset to start value (\(initial.shortText))", systemImage: "arrow.uturn.backward") {
                Task { await apply(.setValue(initial)) }
            }
        }
    }
}
