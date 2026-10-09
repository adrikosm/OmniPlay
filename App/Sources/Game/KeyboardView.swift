import InputKit
import SwiftUI

/// The full keyboard the keys button swaps in for the touch pad (INPUT-009): Esc and the digits (Fn turns them into
/// F1–F12), the letter rows, Enter, Tab, Backspace, the arrows and Space. A key goes down under the finger and up when
/// it lifts, so holding one holds it in the game. Shift, Ctrl and Alt are sticky: tap Ctrl, then S sends Ctrl+S, and
/// the modifier lets go after that key. Aa opens a text field that sends what was typed as text, for games that read
/// typed text rather than keys. Everything held is let go when the keyboard goes away.
struct KeyboardView: View {
    let opacity: Double
    let send: (GameInputEvent) -> Void
    @State private var held: Set<GameKey> = []
    @State private var pressed: Set<GameKey> = []
    @State private var function = false
    @State private var typing = false
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    private struct Key: Identifiable {
        let code: GameKey
        let label: String
        var weight: CGFloat = 1
        var id: String { code.rawValue }
    }

    private static func letters(_ row: String) -> [Key] {
        row.compactMap { c in GameKey.letter(c).map { Key(code: $0, label: String(c)) } }
    }

    private static let fn = GameKey(rawValue: "Fn")
    private static let aa = GameKey(rawValue: "Aa")
    private static let modifiers: Set<GameKey> = [.shiftLeft, .controlLeft, .altLeft]

    private var rows: [[Key]] {
        let top = function ? (1 ... 12).map { Key(code: GameKey(rawValue: "F\($0)"), label: "F\($0)") } : Self.letters("1234567890")
        return [
            [Key(code: .escape, label: "Esc")] + top + [Key(code: .backspace, label: "⌫", weight: 1.5)],
            [Key(code: .tab, label: "Tab", weight: 1.5)] + Self.letters("QWERTYUIOP"),
            [Key(code: Self.fn, label: "Fn", weight: 1.5)] + Self.letters("ASDFGHJKL") + [Key(code: .enter, label: "Enter", weight: 1.75)],
            [Key(code: .shiftLeft, label: "Shift", weight: 2)] + Self.letters("ZXCVBNM") + [Key(code: .arrowUp, label: "↑")],
            [
                Key(code: .controlLeft, label: "Ctrl", weight: 1.5), Key(code: .altLeft, label: "Alt", weight: 1.5),
                Key(code: Self.aa, label: "Aa", weight: 1.5), Key(code: .space, label: "Space", weight: 5),
                Key(code: .arrowLeft, label: "←"), Key(code: .arrowDown, label: "↓"), Key(code: .arrowRight, label: "→"),
            ],
        ]
    }

    var body: some View {
        VStack(spacing: Theme.s2) {
            if typing {
                HStack(spacing: Theme.s2) {
                    TextField("Text for the game", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($fieldFocused)
                        .submitLabel(.send)
                        .accessibilityLabel("Text for the game")
                        .onSubmit(submit)
                        .padding(.horizontal, Theme.s3)
                        .frame(minHeight: 44)
                        .surface(radius: 12)
                    Button("Done") {
                        submit()
                        typing = false
                    }
                    .buttonStyle(.link)
                }
            }
            VStack(spacing: 4) {
                ForEach(rows.indices, id: \.self) { row($0) }
            }
            .padding(6)
            .surface(radius: 16)
            .opacity(max(opacity, 0.6))
        }
        .frame(maxWidth: 720)
        .onDisappear { releaseAll() }
    }

    private func row(_ index: Int) -> some View {
        let keys = rows[index]
        return GeometryReader { geometry in
            let unit = (geometry.size.width - CGFloat(keys.count - 1) * 4) / keys.reduce(0) { $0 + $1.weight }
            HStack(spacing: 4) {
                ForEach(keys) { key in
                    cap(key).frame(width: max(0, unit * key.weight))
                }
            }
        }
        .frame(height: 34)
    }

    @ViewBuilder private func cap(_ key: Key) -> some View {
        let active = held.contains(key.code) || pressed.contains(key.code) || (key.code == Self.fn && function)
            || (key.code == Self.aa && typing)
        let face = Text(key.label)
            .font(.system(size: 13, weight: .semibold))
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .foregroundStyle(active ? Theme.canvas : Theme.textPrimary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(active ? Theme.textPrimary : Theme.fill, in: .rect(cornerRadius: 7, style: .continuous))
            .contentShape(.rect)
            .accessibilityLabel(key.code.rawValue)
            .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        if Self.modifiers.contains(key.code) || key.code == Self.fn || key.code == Self.aa {
            face.onTapGesture { tap(key.code) }
        } else {
            // Down while touched, up when the finger lifts: a held arrow walks.
            face.gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in down(key.code) }
                .onEnded { _ in up(key.code) })
        }
    }

    private func tap(_ code: GameKey) {
        Haptics.tap()
        switch code {
        case Self.fn: function.toggle()
        case Self.aa:
            typing.toggle()
            fieldFocused = typing
        default:
            if held.remove(code) != nil {
                send(.keyUp(code))
            } else {
                held.insert(code)
                send(.keyDown(code))
            }
        }
    }

    private func down(_ code: GameKey) {
        guard pressed.insert(code).inserted else { return }
        Haptics.tap()
        send(.keyDown(code))
    }

    private func up(_ code: GameKey) {
        guard pressed.remove(code) != nil else { return }
        send(.keyUp(code))
        releaseModifiers()
    }

    private func releaseModifiers() {
        for modifier in held {
            send(.keyUp(modifier))
        }
        held = []
    }

    private func releaseAll() {
        for code in pressed {
            send(.keyUp(code))
        }
        pressed = []
        releaseModifiers()
    }

    /// Sends the field's text, then clears it and closes the system keyboard.
    private func submit() {
        if !text.isEmpty {
            send(.text(text))
        }
        text = ""
        fieldFocused = false
    }
}
