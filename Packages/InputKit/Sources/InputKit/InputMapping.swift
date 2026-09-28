/// Controller → keyboard translation. Adapters that speak keyboard (web, mkxp) get key events; those with
/// native pad support can read the raw controller events instead.
public struct InputMapping: Codable, Sendable, Hashable {
    public var buttons: [ControllerButton: [GameKey]]
    /// Left stick past this magnitude acts as the D-pad.
    public var stickDeadzone: Float

    public init(buttons: [ControllerButton: [GameKey]], stickDeadzone: Float = 0.5) {
        self.buttons = buttons
        self.stickDeadzone = stickDeadzone
    }

    /// RPG Maker defaults: Enter ok (Z is XP's A button), X cancel, Shift dash, Q/W page, Escape menu.
    public static let rpgMaker = InputMapping(buttons: [
        .a: [.enter], .b: [.keyX], .x: [.shiftLeft], .y: [.keyQ],
        .leftShoulder: [.keyQ], .rightShoulder: [.keyW],
        .dpadUp: [.arrowUp], .dpadDown: [.arrowDown], .dpadLeft: [.arrowLeft], .dpadRight: [.arrowRight],
        .menu: [.escape], .options: [.escape],
    ])

    public func keys(for button: ControllerButton) -> [GameKey] { buttons[button] ?? [] }

    /// The buttons a player can map. Options opens OmniPlay's menu and Home belongs to the system.
    public static let mappable: [ControllerButton] = [
        .a, .b, .x, .y, .leftShoulder, .rightShoulder, .leftTrigger, .rightTrigger,
        .dpadUp, .dpadDown, .dpadLeft, .dpadRight, .menu, .leftThumbstickButton, .rightThumbstickButton,
    ]

    /// Key events for a button change; unmapped buttons give none.
    public func translate(_ button: ControllerButton, pressed: Bool) -> [GameInputEvent] {
        keys(for: button).map { pressed ? .keyDown($0) : .keyUp($0) }
    }
}

/// Turns a stick position into arrow key transitions, remembering what is held so releases are exact.
public struct StickToArrows: Sendable, Hashable {
    private var held: Set<GameKey> = []
    public let deadzone: Float

    public init(deadzone: Float = 0.5) { self.deadzone = deadzone }

    /// `y` follows GameController: up is positive.
    public mutating func update(x: Float, y: Float) -> [GameInputEvent] {
        var wanted: Set<GameKey> = []
        if x > deadzone {
            wanted.insert(.arrowRight)
        }
        if x < -deadzone {
            wanted.insert(.arrowLeft)
        }
        if y > deadzone {
            wanted.insert(.arrowUp)
        }
        if y < -deadzone {
            wanted.insert(.arrowDown)
        }
        let released = held.subtracting(wanted).sorted { $0.rawValue < $1.rawValue }
        let pressed = wanted.subtracting(held).sorted { $0.rawValue < $1.rawValue }
        held = wanted
        return released.map(GameInputEvent.keyUp) + pressed.map(GameInputEvent.keyDown)
    }

    public mutating func releaseAll() -> [GameInputEvent] { update(x: 0, y: 0) }
}
