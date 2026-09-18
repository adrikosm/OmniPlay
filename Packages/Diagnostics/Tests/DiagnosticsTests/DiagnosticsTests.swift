import Diagnostics
import Testing

@Suite("Diagnostics")
struct DiagnosticsTests {
    @Test("Every §18 category is present exactly once")
    func categoriesMatchDesignAuthority() {
        let expected: Set = [
            "importer", "detection", "runtime", "filesystem", "web", "javascript", "ruby", "python",
            "godot", "scummvm", "renderer", "audio", "save", "memory", "media", "crash", "compatibility",
        ]
        #expect(Set(LogCategory.allCases.map(\.rawValue)) == expected)
        #expect(LogCategory.allCases.count == expected.count)
    }

    @Test("Session IDs are unique")
    func sessionIDsAreUnique() {
        #expect(SessionID() != SessionID())
    }
}
