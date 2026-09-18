import GameStore
import Testing

@Suite("GameStore") struct GameStoreTests {
    @Test("Module links") func links() { _ = GameStoreModule.self }
}
