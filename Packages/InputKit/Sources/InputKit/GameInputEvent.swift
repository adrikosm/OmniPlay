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

/// USB-HID keyboard usage ID. mkxp-z's `mkxp_injectKeyEvent` and SDL scancodes both speak HID usages.
public struct GameKey: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }
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
