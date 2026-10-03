import Foundation

/// A virtual-controls layout per orientation, with the opacity the player chose. Stored per game.
public struct ControlsLayoutSet: Codable, Sendable, Hashable {
    public var landscape: ControlsLayout
    public var portrait: ControlsLayout
    /// 0…1, or nil for the app's own setting.
    public var opacity: Double?
    /// Where it came from ("joiplay", "kirin", "user"), for the Controls screen.
    public var source: String

    public init(landscape: ControlsLayout, portrait: ControlsLayout, opacity: Double? = nil, source: String) {
        (self.landscape, self.portrait, self.opacity, self.source) = (landscape, portrait, opacity, source)
    }
}

/// JoiPlay's `gamepad.json` (shipped inside `.jgp` packages) as an OmniPlay layout. The file only says which Android
/// keycode each of JoiPad's ten buttons sends (`aKeyCode`…`crKeyCode`, `…KeyCode1` for the alternative set), plus
/// `btnOpacity`, `btnScale`, `diagonalMovement` and `hideGamepad`, each wrapped as `{"int": n}` or `{"boolean": b}`
/// (JoiPlay's MIT `commons` GamePadParser). The file has no positions, so buttons go where JoiPad puts them; keycodes become W3C
/// key codes, and a code with no keyboard equivalent is dropped with a note.
public enum JoiPlayLayoutImporter {
    public struct Result: Sendable {
        public var layouts: ControlsLayoutSet
        public var notes: [String]
    }

    /// JoiPad's buttons with their default keys (JoiPlay `commons` GamePad) and places in the arrangement JoiPad's
    /// `gamepad_layout.xml` uses, landscape then portrait: X/Y/A/B/Z as a diamond at the bottom right (X on top, Z at
    /// the bottom, A in the middle), L with CL and CR with R in a row above the pad, C beside the diamond.
    struct Slot {
        let id, label: String
        let defaultCode: Int
        let landscape, portrait: (Double, Double)
        init(_ id: String, _ label: String, _ defaultCode: Int, _ landscape: (Double, Double), _ portrait: (Double, Double)) {
            (self.id, self.label, self.defaultCode, self.landscape, self.portrait) = (id, label, defaultCode, landscape, portrait)
        }
    }

    static let slots: [Slot] = [
        Slot("x", "X", 54, (0.86, 0.56), (0.84, 0.70)),
        Slot("y", "Y", 113, (0.78, 0.70), (0.72, 0.80)),
        Slot("a", "A", 52, (0.86, 0.70), (0.84, 0.80)),
        Slot("b", "B", 59, (0.94, 0.70), (0.95, 0.80)),
        Slot("z", "Z", 45, (0.86, 0.84), (0.84, 0.90)),
        Slot("c", "C", 46, (0.72, 0.84), (0.68, 0.92)),
        Slot("l", "L", 66, (0.06, 0.28), (0.08, 0.56)),
        Slot("cl", "CL", 132, (0.16, 0.28), (0.22, 0.56)),
        Slot("cr", "CR", 139, (0.84, 0.28), (0.78, 0.56)),
        Slot("r", "R", 111, (0.94, 0.28), (0.92, 0.56)),
    ]

    public static func translate(_ data: Data) throws -> Result {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        let pad = root["gamepad"] as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? { (pad[key] as? [String: Any])?["int"] as? Int }
        func bool(_ key: String) -> Bool? { (pad[key] as? [String: Any])?["boolean"] as? Bool }
        var notes: [String] = []
        let scale = Double(int("btnScale") ?? 100) / 100
        let opacity = int("btnOpacity").map { min(max(Double($0) / 100, 0.1), 1) }
        var landscape: [ControlsLayout.Control] = []
        var portrait: [ControlsLayout.Control] = []
        for slot in slots {
            let codes = [int("\(slot.id)KeyCode") ?? slot.defaultCode, int("\(slot.id)KeyCode1")].compactMap(\.self)
            guard let code = codes.first else { continue }
            guard let key = androidKey(code) else {
                notes
                    .append(
                        "JoiPlay button \(slot.label) sends Android key \(code), which has no keyboard equivalent here; it was left out."
                    )
                continue
            }
            let control = { (at: (Double, Double)) in
                ControlsLayout.Control(
                    id: "joiplay.\(slot.id)",
                    label: label(for: key, slot: slot.label),
                    keys: [key],
                    anchor: .init(x: at.0, y: at.1, size: 52 * scale)
                )
            }
            landscape.append(control(slot.landscape))
            portrait.append(control(slot.portrait))
        }
        if bool("diagonalMovement") == true {
            notes.append("JoiPlay's diagonal movement setting has no equivalent; the D-pad moves in four directions.")
        }
        let set = ControlsLayoutSet(
            landscape: ControlsLayout(dpad: .init(x: 0.14, y: 0.70, size: 168 * scale), buttons: landscape),
            portrait: ControlsLayout(dpad: .init(x: 0.22, y: 0.82, size: 160 * scale), buttons: portrait),
            opacity: opacity,
            source: "joiplay"
        )
        return Result(layouts: set, notes: notes)
    }

    /// The key's own name where it has one (Enter, Esc, F2); otherwise JoiPad's button letter.
    static func label(for key: GameKey, slot: String) -> String {
        switch key.rawValue {
        case "Enter": "Enter"
        case "Escape": "Esc"
        case "ShiftLeft", "ShiftRight": "Shift"
        case "ControlLeft", "ControlRight": "Ctrl"
        case "Space": "Space"
        case let raw where raw.hasPrefix("F") && Int(raw.dropFirst()) != nil: raw
        case let raw where raw.hasPrefix("Key") && raw.count == 4: String(raw.suffix(1))
        default: slot
        }
    }

    /// Android `KeyEvent.KEYCODE_*` to W3C `KeyboardEvent.code`.
    public static func androidKey(_ code: Int) -> GameKey? {
        switch code {
        case 7 ... 16: return GameKey(rawValue: "Digit\(code - 7)")
        case 29 ... 54: return GameKey(rawValue: "Key" + String(UnicodeScalar(UInt8(65 + code - 29))))
        case 131 ... 142: return GameKey(rawValue: "F\(code - 130)")
        default: break
        }
        let table: [Int: String] = [
            19: "ArrowUp", 20: "ArrowDown", 21: "ArrowLeft", 22: "ArrowRight", 23: "Enter", 4: "Escape",
            57: "AltLeft", 58: "AltRight", 59: "ShiftLeft", 60: "ShiftRight", 61: "Tab", 62: "Space", 66: "Enter",
            67: "Backspace", 92: "PageUp", 93: "PageDown", 111: "Escape", 112: "Delete", 113: "ControlLeft",
            114: "ControlRight", 122: "Home", 123: "End", 124: "Insert", 160: "NumpadEnter",
        ]
        return table[code].map(GameKey.init(rawValue:))
    }
}
