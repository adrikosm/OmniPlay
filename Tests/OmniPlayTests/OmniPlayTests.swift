@testable import OmniPlay
import Testing

@Suite("App shell")
struct OmniPlayTests {
    @Test("Root view constructs")
    @MainActor
    func rootViewConstructs() {
        _ = RootView()
    }
}
