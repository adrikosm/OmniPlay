import InputKit
import Testing

@Suite("InputKit")
struct InputKitTests {
    @Test("Events are value types usable as dictionary keys")
    func eventsHashable() {
        let events: Set<GameInputEvent> = [
            .keyDown(GameKey(rawValue: 0x04)),
            .keyUp(GameKey(rawValue: 0x04)),
            .pointerMove(x: 1, y: 2),
            .controllerButton(.a, pressed: true),
            .text("あ"),
        ]
        #expect(events.count == 5)
    }
}
