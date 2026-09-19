import Foundation
import GameCore
import GameDetection
import RuntimeCore
import Testing
import TestSupport

@Suite("Runtime resolver")
struct RuntimeResolverTests {
    private func report(_ f: String) throws -> DetectionReport {
        let ctx = try ScanContext(root: Fixtures.url(f))
        defer { ctx.close() }
        return DetectionPipeline.standard.run(ctx, title: f, identityHash: "h")
    }

    @Test("With nothing built the resolver says so; with WebKit bundled MV resolves to it with preparation steps")
    func availability() async throws {
        let mv = try report("mv-basic")
        let empty = RuntimeResolver(registry: RuntimeRegistry())
        let none = await empty.resolve(mv)
        #expect(none.selectedRuntime == nil)
        guard case let .unsupported(why) = none.outcome else { Issue.record("\(none.outcome)"); return }
        #expect(why.contains("no bundled runtime"))
        let registry = RuntimeRegistry()
        await registry.register(.init(
            id: .web,
            families: [.rpgMakerMV, .rpgMakerMZ, .html5],
            generations: [.mv, .mz],
            version: "webkit",
            flags: [.saves],
            availability: .bundled
        ))
        let res = await RuntimeResolver(registry: registry).resolve(mv)
        #expect(res.selectedRuntime == .web && res.slot == .web && res.selectedRuntimeVersion == "webkit")
        #expect(res.requiredPreparation.contains(.installHostShims(.rpgMakerMV)) && res.requiredPreparation.contains(.buildCaseIndex))
        #expect(res.outcome == .supported)
    }

    @Test("Override wins when the runtime exists; unknown override is ignored with a note; refusals resolve to nothing")
    func overrides() async throws {
        let ace = try report("rgss-vxace")
        let registry = RuntimeRegistry()
        await registry.register(.init(
            id: .rgss(ruby: .ruby31),
            families: [.rpgMakerVXAce],
            generations: [.rgss3],
            version: "3.1",
            flags: [],
            availability: .bundled
        ))
        await registry.register(.init(
            id: .rgss(ruby: .ruby19),
            families: [.rpgMakerVXAce],
            generations: [.rgss3],
            version: "1.9",
            flags: [],
            availability: .bundled
        ))
        let auto = await RuntimeResolver(registry: registry).resolve(ace)
        #expect(auto.selectedRuntime == .rgss(ruby: .ruby19) && !auto.manualOverride)
        let manual = await RuntimeResolver(registry: registry).resolve(ace, override: .rgss(ruby: .ruby31))
        #expect(manual.selectedRuntime == .rgss(ruby: .ruby31) && manual.manualOverride && manual.reason == "manual override")
        let bogus = await RuntimeResolver(registry: registry).resolve(ace, override: .tic80)
        #expect(bogus.selectedRuntime == .rgss(ruby: .ruby19))
        #expect(bogus.warnings.contains {
            if case let .note(n) = $0 {
                n.contains("not part of this build")
            } else {
                false
            }
        })
        let unity = try report("unity-native-il2cpp")
        let refused = await RuntimeResolver(registry: registry).resolve(unity)
        #expect(refused.selectedRuntime == nil && refused.reason.contains("Unity"))
    }
}
