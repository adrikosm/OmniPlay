import OverlayVFS
import Testing

@Suite("OverlayVFS") struct OverlayVFSTests {
    @Test("Module links") func links() { _ = OverlayVFSModule.self }
}
