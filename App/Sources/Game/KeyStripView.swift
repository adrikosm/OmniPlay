import InputKit
import SwiftUI

/// The keys a phone has no way to press (INPUT-009): Esc, Tab, Enter, the modifiers, the arrows and F1–F12 in one
/// scrolling strip, plus a text field for typing into games that read the keyboard. Modifiers are sticky: tap Ctrl,
/// then F5 sends Ctrl+F5, and the modifier lets go after that key. The text field sends what was typed as text
/// and closes the keyboard on Return or Done, whatever the game does.
struct KeyStripView: View {
    let send: (GameInputEvent) -> Void
    @State private var held: Set<GameKey> = []
    @State private var typing = false
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    private static let modifiers: [(GameKey, String)] = [(.controlLeft, "Ctrl"), (.altLeft, "Alt"), (.shiftLeft, "Shift")]
    private static let keys: [(GameKey, String)] = [
        (.escape, "Esc"), (.tab, "Tab"), (.enter, "Enter"), (.space, "Space"), (.backspace, "⌫"),
        (.arrowUp, "↑"), (.arrowDown, "↓"), (.arrowLeft, "←"), (.arrowRight, "→"),
    ] + (1 ... 12).map { (GameKey(rawValue: "F\($0)"), "F\($0)") }

    var body: some View {
        VStack(spacing: Theme.s2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.s2) {
                    Button { typing.toggle(); fieldFocused = typing } label: { cap("Aa", active: typing) }
                        .accessibilityLabel("Type text")
                    ForEach(Self.modifiers, id: \.0.rawValue) { key, name in
                        Button { toggle(key) } label: { cap(name, active: held.contains(key)) }
                            .accessibilityLabel(name)
                            .accessibilityAddTraits(held.contains(key) ? .isSelected : [])
                    }
                    ForEach(Self.keys, id: \.0.rawValue) { key, name in
                        Button { press(key) } label: { cap(name, active: false) }
                            .accessibilityLabel(key.rawValue)
                    }
                }
                .padding(.horizontal, Theme.s3)
            }
            .frame(height: 48)
            .surface(radius: 16)
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
        }
        .frame(maxWidth: 620)
        .onDisappear { release() }
    }

    private func cap(_ name: String, active: Bool) -> some View {
        Text(name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(active ? Theme.canvas : Theme.textPrimary)
            .padding(.horizontal, Theme.s3)
            .frame(minWidth: 44, minHeight: 36)
            .background(active ? Theme.textPrimary : Theme.fill, in: .rect(cornerRadius: 10, style: .continuous))
            .frame(minHeight: 44)
    }

    private func toggle(_ modifier: GameKey) {
        if held.remove(modifier) != nil {
            send(.keyUp(modifier))
        } else {
            held.insert(modifier)
            send(.keyDown(modifier))
        }
        Haptics.tap()
    }

    private func press(_ key: GameKey) {
        Haptics.tap()
        send(.keyDown(key))
        send(.keyUp(key))
        release()
    }

    private func release() {
        for modifier in held {
            send(.keyUp(modifier))
        }
        held = []
    }

    /// Sends the field's text, then clears it and closes the keyboard.
    private func submit() {
        if !text.isEmpty {
            send(.text(text))
        }
        text = ""
        fieldFocused = false
    }
}
