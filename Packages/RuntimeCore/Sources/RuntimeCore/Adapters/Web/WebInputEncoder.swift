import Foundation
import InputKit

/// `GameInputEvent` → the JSON array `omniplay-input.js` consumes. Pure so it is testable without WebKit.
enum WebInputEncoder {
    static func json(_ events: [GameInputEvent]) -> String {
        let items: [[String: Any]] = events.map { event in
            switch event {
            case let .keyDown(key): ["t": "key", "down": true, "code": key.rawValue, "key": key.domKey, "keyCode": key.domKeyCode]
            case let .keyUp(key): ["t": "key", "down": false, "code": key.rawValue, "key": key.domKey, "keyCode": key.domKeyCode]
            case let .pointerMove(x, y): ["t": "pointer", "phase": "move", "x": x, "y": y, "button": "primary"]
            case let .pointerDown(button, x, y): ["t": "pointer", "phase": "down", "x": x, "y": y, "button": button.rawValue]
            case let .pointerUp(button, x, y): ["t": "pointer", "phase": "up", "x": x, "y": y, "button": button.rawValue]
            case let .scroll(dx, dy): ["t": "scroll", "dx": dx, "dy": dy]
            case let .controllerButton(button, pressed): ["t": "pad", "button": button.rawValue, "pressed": pressed]
            case let .controllerAxis(axis, value): ["t": "axis", "axis": axis.rawValue, "value": Double(value)]
            case let .text(text): ["t": "text", "text": String(text.prefix(64))]
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys]) else { return "[]" }
        return String(bytes: data, encoding: .utf8) ?? "[]"
    }
}
