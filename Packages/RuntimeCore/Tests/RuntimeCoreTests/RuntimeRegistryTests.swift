import Foundation
import GameCore
import RuntimeCore
import Testing

@Suite("Runtime registry")
struct RuntimeRegistryTests {
    @Test("Lookup by family and generation; everything planned is honest about not being built")
    func lookup() async throws {
        let registry = RuntimeRegistry()
        let ace = await registry.descriptors(for: .rpgMakerVXAce, generation: .rgss3).map(\.id)
        #expect(ace.contains(.rgss(ruby: .ruby19)) && ace.contains(.rgss(ruby: .ruby31)) && !ace.contains(.rgss(ruby: .ruby18)))
        #expect(await registry.descriptors(for: .renpy, generation: .renpyPy27).map(\.id).contains(.renpy(engine: .v787)))
        #expect(await registry.all.allSatisfy { $0.availability == .notBuilt })
        await registry.register(.init(
            id: .web,
            families: [.html5],
            generations: [],
            version: "test",
            flags: [.saves],
            availability: .bundled
        ))
        #expect(await registry.descriptor(for: .web)?.availability == .bundled)
        let flags: RuntimeCapabilityFlags = [.saves, .cheats]
        let data = try JSONEncoder().encode(flags)
        #expect(try JSONDecoder().decode(RuntimeCapabilityFlags.self, from: data) == flags)
    }
}
