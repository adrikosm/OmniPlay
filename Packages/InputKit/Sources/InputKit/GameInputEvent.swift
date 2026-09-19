/// The single input vocabulary every adapter consumes (design authority §16). `InputKit` emits these
/// from touch overlays, `GameController` and hardware keyboards; adapters translate to DOM events,
/// SDL events, Ren'Py input, RGSS `Input`, Godot input or ScummVM events. Adapters never read raw touches.
public enum GameInputEvent: Sendable, Hashable {
    case keyDown(GameKey)
    case keyUp(GameKey)
    case pointerMove(x: Double, y: Double)
    case pointerDown(PointerButton, x: Double, y: Double)
    case pointerUp(PointerButton, x: Double, y: Double)
    case scroll(dx: Double, dy: Double)
    case controllerButton(ControllerButton, pressed: Bool)
    case controllerAxis(ControllerAxis, value: Float)
    case text(String)
}

/// A key named by its W3C `KeyboardEvent.code` ("ArrowUp", "KeyZ", "Enter"). The DOM `key` and legacy
/// `keyCode` that RPG Maker's `Input.keyMapper` still reads are derived here so adapters never guess.
public struct GameKey: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static let arrowUp = GameKey(rawValue: "ArrowUp")
    public static let arrowDown = GameKey(rawValue: "ArrowDown")
    public static let arrowLeft = GameKey(rawValue: "ArrowLeft")
    public static let arrowRight = GameKey(rawValue: "ArrowRight")
    public static let enter = GameKey(rawValue: "Enter")
    public static let escape = GameKey(rawValue: "Escape")
    public static let space = GameKey(rawValue: "Space")
    public static let tab = GameKey(rawValue: "Tab")
    public static let backspace = GameKey(rawValue: "Backspace")
    public static let shiftLeft = GameKey(rawValue: "ShiftLeft")
    public static let controlLeft = GameKey(rawValue: "ControlLeft")
    public static let altLeft = GameKey(rawValue: "AltLeft")
    public static let pageUp = GameKey(rawValue: "PageUp")
    public static let pageDown = GameKey(rawValue: "PageDown")
    public static let home = GameKey(rawValue: "Home")
    public static let end = GameKey(rawValue: "End")
    public static let insert = GameKey(rawValue: "Insert")
    public static let delete = GameKey(rawValue: "Delete")
    public static let keyZ = GameKey(rawValue: "KeyZ")
    public static let keyX = GameKey(rawValue: "KeyX")
    public static let keyQ = GameKey(rawValue: "KeyQ")
    public static let keyW = GameKey(rawValue: "KeyW")
    public static let keyA = GameKey(rawValue: "KeyA")
    public static let keyS = GameKey(rawValue: "KeyS")
    public static let keyD = GameKey(rawValue: "KeyD")
    public static let keyF = GameKey(rawValue: "KeyF")
    public static let f5 = GameKey(rawValue: "F5")

    /// `KeyA`…`KeyZ` for a Latin letter, `Digit0`…`Digit9` for a digit.
    public static func letter(_ character: Character) -> GameKey? {
        let upper = character.uppercased()
        guard upper.count == 1, let scalar = upper.unicodeScalars.first else { return nil }
        if ("A" ... "Z").contains(scalar) {
            return GameKey(rawValue: "Key\(upper)")
        }
        if ("0" ... "9").contains(scalar) {
            return GameKey(rawValue: "Digit\(upper)")
        }
        return nil
    }

    /// `KeyboardEvent.key`: printable keys give their character, everything else the code itself.
    public var domKey: String {
        if rawValue.hasPrefix("Key"), rawValue.count == 4 {
            return rawValue.suffix(1).lowercased()
        }
        if rawValue.hasPrefix("Digit"), rawValue.count == 6 {
            return String(rawValue.suffix(1))
        }
        switch rawValue {
        case "Space": return " "
        case "ShiftLeft", "ShiftRight": return "Shift"
        case "ControlLeft", "ControlRight": return "Control"
        case "AltLeft", "AltRight": return "Alt"
        default: return rawValue
        }
    }

    /// Legacy `KeyboardEvent.keyCode`, or 0 for keys this table does not know.
    public var domKeyCode: Int {
        if rawValue.hasPrefix("Key"), rawValue.count == 4, let ascii = rawValue.last?.asciiValue {
            return Int(ascii)
        }
        if rawValue.hasPrefix("Digit"), rawValue.count == 6, let ascii = rawValue.last?.asciiValue {
            return Int(ascii)
        }
        if rawValue.hasPrefix("F"), let n = Int(rawValue.dropFirst()), (1 ... 12).contains(n) {
            return 111 + n
        }
        return Self.keyCodes[rawValue] ?? 0
    }

    private static let keyCodes: [String: Int] = [
        "Backspace": 8, "Tab": 9, "Enter": 13, "ShiftLeft": 16, "ShiftRight": 16, "ControlLeft": 17, "ControlRight": 17,
        "AltLeft": 18, "AltRight": 18, "Escape": 27, "Space": 32, "PageUp": 33, "PageDown": 34, "End": 35, "Home": 36,
        "ArrowLeft": 37, "ArrowUp": 38, "ArrowRight": 39, "ArrowDown": 40, "Insert": 45, "Delete": 46,
    ]
}

public enum PointerButton: String, Sendable, Codable, Hashable, CaseIterable {
    case primary
    case secondary
    case middle
}

public enum ControllerButton: String, Sendable, Codable, Hashable, CaseIterable {
    case a, b, x, y
    case leftShoulder, rightShoulder
    case leftTrigger, rightTrigger
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case menu, options, home
    case leftThumbstickButton, rightThumbstickButton
}

public enum ControllerAxis: String, Sendable, Codable, Hashable, CaseIterable {
    case leftX, leftY
    case rightX, rightY
    case leftTrigger, rightTrigger
}
