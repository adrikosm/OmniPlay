import GameTools
import RuntimeCore
import SwiftUI

/// One value on its own: the whole name and the whole value, both selectable, with room to edit long text, and the
/// same watch, freeze and save actions as the row's menu.
struct VariableDetail: View {
    let entry: StateEntry
    let live: StateValue?
    let tools: MutationEngine
    let error: String?
    let apply: (ToolOperation) async -> Void
    var save: (() -> Void)?
    let close: () -> Void
    @State private var draft = ""
    @State private var invalid: String?
    @State private var pending = false
    @FocusState private var editing: Bool

    private var value: StateValue { live ?? entry.value }
    private var frozen: Bool { tools.frozen[entry.target] != nil }
    private var watched: Bool { tools.watched[entry.target] != nil }
    private var heading: String { entry.target.shortDescription }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            SheetHeader(title: heading, close: close)
            VStack(alignment: .leading, spacing: Theme.s1) {
                Text("Name").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                Text(entry.name.isEmpty ? entry.target.shortDescription : entry.name)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: Theme.s2) {
                Text("Value").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                editor
                if let message = invalid ?? error {
                    Text(message).font(.footnote).foregroundStyle(Theme.danger)
                }
            }
            if entry.editable, value.isPlain {
                actions
            }
        }
        .disabled(pending)
        .onAppear { draft = Self.text(of: value) }
        .onChange(of: value) { _, new in
            if !editing {
                draft = Self.text(of: new)
            }
        }
    }

    @ViewBuilder private var editor: some View {
        switch value {
        case let .bool(on) where entry.editable:
            Toggle(on ? "On" : "Off", isOn: Binding(get: { on }, set: { send(.setValue(.bool($0))) }))
                .font(.subheadline).foregroundStyle(Theme.textPrimary)
        case .string where entry.editable:
            TextEditor(text: $draft)
                .focused($editing)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 88, maxHeight: 220)
                .padding(Theme.s2)
                .background(Theme.fill, in: .rect(cornerRadius: Theme.fieldRadius, style: .continuous))
            saveButton
        case .int where entry.editable, .double where entry.editable:
            HStack(spacing: Theme.s3) {
                TextField("Value", text: $draft)
                    .focused($editing)
                    .keyboardType(.numbersAndPunctuation)
                    .font(Theme.value)
                    .foregroundStyle(Theme.textPrimary)
                    .submitLabel(.done)
                    .onSubmit(commit)
                    .padding(.horizontal, Theme.s3)
                    .frame(minHeight: 44)
                    .background(Theme.fill, in: .rect(cornerRadius: Theme.fieldRadius, style: .continuous))
                saveButton
            }
        default:
            Text(Self.text(of: value))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var saveButton: some View {
        Button(pending ? "Saving…" : "Set value", action: commit)
            .buttonStyle(PillButtonStyle(kind: .primary, height: 44))
            .disabled(draft == Self.text(of: value))
    }

    /// Watch, freeze and keep as a cheat, as buttons rather than a menu: there is room here.
    private var actions: some View {
        HStack(spacing: Theme.s2) {
            if tools.capabilities.contains(.live) {
                Button(watched ? "Stop watching" : "Watch", systemImage: watched ? "eye.slash" : "eye") {
                    watched ? tools.unwatch(entry.target) : tools.watch(entry.target)
                }
                if !entry.persistent {
                    Button(frozen ? "Unfreeze" : "Freeze", systemImage: "snowflake") {
                        Task {
                            if frozen {
                                await tools.unfreeze(entry.target)
                            } else {
                                await tools.freeze(entry.target, at: value)
                            }
                        }
                    }
                }
            }
            if let save {
                Button("Save as cheat", systemImage: "star", action: save)
            }
        }
        .buttonStyle(PillButtonStyle(kind: .secondary, height: 40))
        .font(.footnote.weight(.semibold))
    }

    private func commit() {
        guard let typed = value.parse(draft) else {
            invalid = "“\(draft)” is not a \(value.isInt ? "whole number" : "number")."
            return
        }
        invalid = nil
        editing = false
        send(.setValue(typed))
    }

    private func send(_ operation: ToolOperation) {
        pending = true
        Task {
            await apply(operation)
            pending = false
        }
    }

    /// Text as it is (no quotes), numbers without grouping so they can be edited, everything else as the list shows it.
    static func text(of value: StateValue) -> String {
        switch value {
        case let .string(s): s
        case let .int(i): String(i)
        case let .double(d): String(d)
        default: value.shortText
        }
    }
}
