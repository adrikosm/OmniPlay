#if canImport(GameController)
    import Foundation
    import GameController

    /// Physical controllers and hardware keyboards through `GameController`, translated with an `InputMapping`
    /// and pushed onto an `InputBus`. Raw controller events go out too, for adapters with native pad support.
    @MainActor
    public final class ControllerCapture {
        public let bus: InputBus
        public var mapping: InputMapping
        public private(set) var connectedControllers = 0
        public private(set) var connectedNames: [String] = []
        public var onControllerCountChanged: (@MainActor (Int) -> Void)?
        private var stick = StickToArrows()
        private var observers: [any NSObjectProtocol] = []

        public init(bus: InputBus, mapping: InputMapping = .rpgMaker) {
            self.bus = bus
            self.mapping = mapping
            stick = StickToArrows(deadzone: mapping.stickDeadzone)
        }

        public func start() {
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.attachAll() }
                },
                center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshCount() }
                },
                center.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.attachKeyboard() }
                },
            ]
            attachAll()
            attachKeyboard()
            GCController.startWirelessControllerDiscovery {}
        }

        public func stop() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            GCController.controllers().forEach { $0.extendedGamepad?.valueChangedHandler = nil }
            GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = nil
            bus.send(stick.releaseAll())
        }

        /// Only full gamepads count; a remote or a micro pad cannot drive a game on its own.
        private func refreshCount() {
            let pads = GCController.controllers().filter { $0.extendedGamepad != nil }
            connectedControllers = pads.count
            connectedNames = pads.map { $0.vendorName ?? "controller" }
            onControllerCountChanged?(connectedControllers)
        }

        private func attachAll() {
            refreshCount()
            for pad in GCController.controllers().compactMap(\.extendedGamepad) where pad.valueChangedHandler == nil {
                pad.valueChangedHandler = { [weak self] pad, element in
                    MainActor.assumeIsolated { self?.handle(pad: pad, element: element) }
                }
            }
        }

        private func attachKeyboard() {
            GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = { [weak self] _, _, code, pressed in
                guard let key = Self.key(for: code) else { return }
                MainActor.assumeIsolated { self?.bus.send(pressed ? .keyDown(key) : .keyUp(key)) }
            }
        }

        private func handle(pad: GCExtendedGamepad, element: GCControllerElement) {
            if element == pad.leftThumbstick {
                bus.send(.controllerAxis(.leftX, value: pad.leftThumbstick.xAxis.value))
                bus.send(.controllerAxis(.leftY, value: pad.leftThumbstick.yAxis.value))
                bus.send(stick.update(x: pad.leftThumbstick.xAxis.value, y: pad.leftThumbstick.yAxis.value))
                return
            }
            if element == pad.rightThumbstick {
                bus.send(.controllerAxis(.rightX, value: pad.rightThumbstick.xAxis.value))
                bus.send(.controllerAxis(.rightY, value: pad.rightThumbstick.yAxis.value))
                return
            }
            let buttons: [(GCControllerButtonInput?, ControllerButton)] = [
                (pad.buttonA, .a), (pad.buttonB, .b), (pad.buttonX, .x), (pad.buttonY, .y),
                (pad.leftShoulder, .leftShoulder), (pad.rightShoulder, .rightShoulder),
                (pad.leftTrigger, .leftTrigger), (pad.rightTrigger, .rightTrigger),
                (pad.dpad.up, .dpadUp), (pad.dpad.down, .dpadDown), (pad.dpad.left, .dpadLeft), (pad.dpad.right, .dpadRight),
                (pad.buttonMenu, .menu), (pad.buttonOptions, .options), (pad.buttonHome, .home),
                (pad.leftThumbstickButton, .leftThumbstickButton), (pad.rightThumbstickButton, .rightThumbstickButton),
            ]
            if element == pad.dpad {
                for (input, button) in buttons where [.dpadUp, .dpadDown, .dpadLeft, .dpadRight].contains(button) {
                    guard let input else { continue }
                    press(button, input.isPressed)
                }
                return
            }
            guard let (input, button) = buttons.first(where: { $0.0 === element }), let input else { return }
            press(button, input.isPressed)
        }

        private var pressed: Set<ControllerButton> = []

        private func press(_ button: ControllerButton, _ down: Bool) {
            guard pressed.contains(button) != down else { return }
            if down {
                pressed.insert(button)
            } else {
                pressed.remove(button)
            }
            bus.send(.controllerButton(button, pressed: down))
            bus.send(mapping.translate(button, pressed: down))
        }

        /// The keys games actually bind; anything else is dropped rather than guessed.
        static func key(for code: GCKeyCode) -> GameKey? {
            switch code {
            case .upArrow: .arrowUp
            case .downArrow: .arrowDown
            case .leftArrow: .arrowLeft
            case .rightArrow: .arrowRight
            case .returnOrEnter: .enter
            case .escape: .escape
            case .spacebar: .space
            case .tab: .tab
            case .deleteOrBackspace: .backspace
            case .leftShift, .rightShift: .shiftLeft
            case .leftControl, .rightControl: .controlLeft
            case .leftAlt, .rightAlt: .altLeft
            case .pageUp: .pageUp
            case .pageDown: .pageDown
            case .home: .home
            case .end: .end
            case .insert: .insert
            case .deleteForward: .delete
            case .F5: .f5
            default: letter(code)
            }
        }

        private static func letter(_ code: GCKeyCode) -> GameKey? {
            // HID usages 0x04–0x1D are A–Z, 0x1E–0x27 are 1–9 then 0.
            let raw = code.rawValue
            if (0x04 ... 0x1D).contains(raw) {
                return GameKey.letter(Character(UnicodeScalar(UInt8(raw - 0x04) + 65)))
            }
            if (0x1E ... 0x27).contains(raw) {
                return GameKey.letter(Character(UnicodeScalar(raw == 0x27 ? 48 : UInt8(raw - 0x1E) + 49)))
            }
            return nil
        }
    }
#endif
