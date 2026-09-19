import Foundation
import InputKit
import Testing

@Suite("InputKit")
struct InputKitTests {
    @Test("Events are value types usable as dictionary keys")
    func eventsHashable() {
        let events: Set<GameInputEvent> = [
            .keyDown(.keyZ),
            .keyUp(.keyZ),
            .pointerMove(x: 1, y: 2),
            .controllerButton(.a, pressed: true),
            .text("あ"),
        ]
        #expect(events.count == 5)
    }

    @Test("Keys carry the DOM key and legacy keyCode RPG Maker reads")
    func domTables() {
        #expect(GameKey.arrowUp.domKeyCode == 38 && GameKey.arrowUp.domKey == "ArrowUp")
        #expect(GameKey.keyZ.domKeyCode == 90 && GameKey.keyZ.domKey == "z")
        #expect(GameKey.enter.domKeyCode == 13 && GameKey.escape.domKeyCode == 27)
        #expect(GameKey.shiftLeft.domKey == "Shift" && GameKey.shiftLeft.domKeyCode == 16)
        #expect(GameKey.space.domKey == " " && GameKey.space.domKeyCode == 32)
        #expect(GameKey.f5.domKeyCode == 116)
        #expect(GameKey.letter("q") == .keyQ && GameKey.letter("7")?.domKeyCode == 55 && GameKey.letter("é") == nil)
        #expect(GameKey(rawValue: "Unknown").domKeyCode == 0)
    }

    @Test("RPG Maker mapping turns buttons into key pairs and sticks into exact arrow transitions")
    func mapping() {
        let m = InputMapping.rpgMaker
        #expect(m.translate(.a, pressed: true) == [.keyDown(.keyZ)])
        #expect(m.translate(.b, pressed: false) == [.keyUp(.keyX)])
        #expect(m.translate(.leftTrigger, pressed: true).isEmpty)
        var stick = StickToArrows(deadzone: 0.5)
        #expect(stick.update(x: 0.9, y: 0.0) == [.keyDown(.arrowRight)])
        #expect(stick.update(x: 0.9, y: 0.9) == [.keyDown(.arrowUp)])
        #expect(stick.update(x: 0.0, y: 0.9) == [.keyUp(.arrowRight)])
        #expect(stick.releaseAll() == [.keyUp(.arrowUp)])
        #expect(stick.releaseAll().isEmpty)
    }

    @Test("Bus delivers to the stream and the synchronous tap")
    @MainActor
    func bus() async {
        let bus = InputBus()
        var tapped: [GameInputEvent] = []
        bus.onEvent = { tapped.append($0) }
        bus.send([.keyDown(.enter), .keyUp(.enter)])
        var iterator = bus.events.makeAsyncIterator()
        #expect(await iterator.next() == .keyDown(.enter))
        #expect(await iterator.next() == .keyUp(.enter))
        #expect(tapped.count == 2)
    }

    @Test("Layouts round-trip as versioned JSON and reject unknown versions")
    func layout() throws {
        let data = try ControlsLayout.landscape.encoded()
        #expect(try ControlsLayout.decode(data) == .landscape)
        #expect(ControlsLayout.portrait.buttons.map(\.id) == ["ok", "cancel", "shift", "menu", "pageUp", "pageDown"])
        var old = ControlsLayout.portrait
        old.version = 0
        #expect(throws: (any Error).self) { try ControlsLayout.decode(old.encoded()) }
        for layout in [ControlsLayout.landscape, .portrait] {
            for control in layout.buttons {
                #expect(control.anchor.size >= 44, Comment(rawValue: control.id))
            }
        }
    }
}
