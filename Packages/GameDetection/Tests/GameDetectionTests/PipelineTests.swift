import Foundation
import GameCore
import GameDetection
import Testing
import TestSupport

@Suite("Detection pipeline")
struct PipelineTests {
    struct Stub: Detector {
        let id: DetectorID
        let version = 1
        let body: @Sendable (ScanContext, StructureFacts) throws -> DetectorReport
        func probe(_ ctx: ScanContext, facts: StructureFacts) throws -> DetectorReport { try body(ctx, facts) }
    }

    struct Boom: Error {}

    private func ctx(_ fixture: String) throws -> ScanContext { try ScanContext(root: Fixtures.url(fixture)) }

    @Test("Models round-trip and evidence is capped at 256")
    func models() throws {
        let long = (0 ..< 300).map { DetectionEvidence(.structure, .present(path: "f\($0)"), confidence: 1, source: .fileName, "x") }
        let capped = DetectionReport.capped(long)
        #expect(capped.count == 256)
        #expect(capped.last?.explanation.contains("45 further") == true)
        let refusal = RefusalReason(engine: .unityNative, humanMessage: "m", technicalDetail: "t", alternatives: ["a"])
        let outcome = DetectionOutcome.refused(refusal)
        let data = try JSONEncoder().encode(outcome)
        #expect(try JSONDecoder().decode(DetectionOutcome.self, from: data) == outcome)
        let ev = long[0]
        #expect(ev.record.check == "structure:f0")
    }

    @Test("Scan context answers existence, headers, listings and globs through the index")
    func context() throws {
        let c = try ctx("mv-basic")
        defer { c.close() }
        #expect(c.exists("WWW/JS/RPG_CORE.JS"))
        #expect(c.header("www/movies/intro.webm", bytes: 4) == Data([0x1A, 0x45, 0xDF, 0xA3]))
        #expect(c.children("www").map(\.realRel).contains("www/js"))
        #expect(c.glob("www/audio/bgm/*.ogg").count == 1)
        #expect(c.text("www/js/rpg_core.js")?.contains("1.6.2") == true)
        #expect(!FileManager.default.fileExists(atPath: c.index.url.path(percentEncoded: false)) || c.count() > 0)
    }

    @Test("Structure facts see markers, www, index candidates and executables")
    func facts() throws {
        let mv = try ctx("mv-basic")
        defer { mv.close() }
        let f = StructureFacts.inspect(mv)
        #expect(f.hasWWW && f.markers.contains(.rpgCoreJS) && f.markers.contains(.systemJSON) && f.markers.contains(.packageJSON))
        #expect(f.indexHTMLCandidates == ["www/index.html"])
        #expect(f.exeNames == ["Game.exe"])
        let xp = try ctx("rgss-xp")
        defer { xp.close() }
        let g = StructureFacts.inspect(xp)
        #expect(g.markers.contains(.gameIni) && g.markers.contains(.rgssArchive))
        let unity = try ctx("unity-native-il2cpp")
        defer { unity.close() }
        let u = StructureFacts.inspect(unity)
        #expect(u.markers.contains(.unityPlayer) && u.markers.contains(.gameAssembly) && u.markers.contains(.unityData))
    }

    @Test("Precedence, refusal override and failures recorded; two runs are identical")
    func orchestration() throws {
        let c = try ctx("empty")
        defer { c.close() }
        let refuser = Stub(id: .refusals) { _, _ in
            var r = DetectorReport()
            r.refusal = RefusalReason(engine: .unityNative, humanMessage: "Unity native", technicalDetail: "UnityPlayer.dll")
            r.claimFamily(.unityNative, 0.95)
            return r
        }
        let family = Stub(id: .rgss) { _, _ in
            var r = DetectorReport(); r.claimFamily(.rpgMakerXP, 0.7); r.partial.generation = .rgss1; return r
        }
        let broken = Stub(id: .renpy) { _, _ in throw Boom() }
        let pipeline = DetectionPipeline(detectors: [refuser, family, broken])
        let a = try pipeline.run(
            c,
            id: GameID(#require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))),
            title: "T",
            identityHash: "h"
        )
        let b = try pipeline.run(
            c,
            id: GameID(#require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))),
            title: "T",
            identityHash: "h"
        )
        guard case let .refused(reason) = a.outcome else { Issue.record("expected refusal, got \(a.outcome)"); return }
        #expect(reason.engine == .unityNative)
        #expect(a.evidence.contains { $0.explanation.contains("renpy failed") })
        #expect(a.detectorVersions["rgss"] == 1)
        var a2 = a, b2 = b
        a2.descriptor.importedAt = Date(timeIntervalSince1970: 0)
        b2.descriptor.importedAt = Date(timeIntervalSince1970: 0)
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let ja = try enc.encode(a2), jb = try enc.encode(b2)
        #expect(ja == jb)
        let noClaims = DetectionPipeline(detectors: [broken]).run(c, title: "T", identityHash: "h")
        #expect(noClaims.outcome == .unknownEngine)
        let close = DetectionPipeline(detectors: [
            Stub(id: .rgss) { _, _ in var r = DetectorReport(); r.claimFamily(.rpgMakerMV, 0.8); r.partial.generation = .mv; return r },
            Stub(id: .html5Web) { _, _ in var r = DetectorReport(); r.claimFamily(.html5, 0.75); return r },
        ]).run(c, title: "T", identityHash: "h")
        #expect(close.outcome == .unknownEngine)
    }
}
