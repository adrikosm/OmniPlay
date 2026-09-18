import LocalGameServer
import Testing

@Suite("LocalGameServer") struct LocalGameServerTests {
    @Test("Module links") func links() { _ = LocalGameServerModule.self }
}
