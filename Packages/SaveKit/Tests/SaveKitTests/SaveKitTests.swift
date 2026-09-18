import SaveKit
import Testing

@Suite("SaveKit")
struct SaveKitTests {
    @Test("Foreign saves are flagged by identity hash or imported origin")
    func foreignDetection() {
        let native = SaveProvenance(gameIdentityHash: "abc", origin: .native)
        let imported = SaveProvenance(gameIdentityHash: "abc", origin: .imported)
        let other = SaveProvenance(gameIdentityHash: "xyz", origin: .native)
        #expect(!native.isForeign(to: "abc"))
        #expect(imported.isForeign(to: "abc"))
        #expect(other.isForeign(to: "abc"))
    }
}
