public extension GameKey {
    /// The key's USB HID keyboard usage (page 0x07), which is what SDL calls a scancode, so every SDL-based
    /// engine takes it as is. A table, never a guess: a code it does not list is nil.
    var hidUsage: Int32? {
        let code = rawValue
        if code.hasPrefix("Key"), code.count == 4, let letter = code.last?.asciiValue, (65 ... 90).contains(letter) {
            return 4 + Int32(letter - 65)
        }
        if code.hasPrefix("Digit"), code.count == 6, let digit = code.last?.wholeNumberValue {
            return digit == 0 ? 39 : 30 + Int32(digit - 1)
        }
        if code.hasPrefix("F"), let n = Int(code.dropFirst()), (1 ... 12).contains(n) {
            return 58 + Int32(n - 1)
        }
        return Self.hidTable[code]
    }

    private static let hidTable: [String: Int32] = [
        "Enter": 40, "Escape": 41, "Backspace": 42, "Tab": 43, "Space": 44,
        "Minus": 45, "Equal": 46, "BracketLeft": 47, "BracketRight": 48, "Backslash": 49,
        "Semicolon": 51, "Quote": 52, "Backquote": 53, "Comma": 54, "Period": 55, "Slash": 56,
        "Insert": 73, "Home": 74, "PageUp": 75, "Delete": 76, "End": 77, "PageDown": 78,
        "ArrowRight": 79, "ArrowLeft": 80, "ArrowDown": 81, "ArrowUp": 82,
        "ControlLeft": 224, "ShiftLeft": 225, "AltLeft": 226, "ControlRight": 228, "ShiftRight": 229, "AltRight": 230,
    ]
}
