import GameTools
import Testing

@Suite("GameTools") struct GameToolsTests {
    @Test("Module links") func links() { _ = GameToolsModule.self }
}
