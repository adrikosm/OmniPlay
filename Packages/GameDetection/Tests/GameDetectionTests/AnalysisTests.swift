import Foundation
import GameCore
import GameDetection
import Testing
import TestSupport

@Suite("Analysis phase", .serialized)
struct AnalysisTests {
    private func report(_ f: String) throws -> (DetectionReport, ScanContext) {
        let ctx = try ScanContext(root: Fixtures.url(f))
        return (DetectionPipeline.standard.run(ctx, title: f, identityHash: "h"), ctx)
    }

    @Test("Ren'Py generations map to the right engine order, RGSS/Godot keep theirs")
    func buckets() throws {
        let (py2, c1) = try report("renpy-7x"); defer { c1.close() }
        #expect(py2.candidateRuntimes.map(\.runtime) == [.renpy(engine: .v787), .renpy(engine: .v853)])
        let (py39, c2) = try report("renpy-81"); defer { c2.close() }
        #expect(py39.candidateRuntimes.first?.runtime == .renpy(engine: .v837))
        let (py312, c3) = try report("renpy-85"); defer { c3.close() }
        #expect(py312.candidateRuntimes.map(\.runtime) == [.renpy(engine: .v853)])
        let (ace, c4) = try report("rgss-vxace"); defer { c4.close() }
        #expect(ace.candidateRuntimes.first?.runtime == .rgss(ruby: .ruby19))
        #expect(ace.descriptor.saveFamily == .rgssMarshal)
    }

    @Test("Media requirements: MV sibling MP4 means no work, MZ VP9-only means a transcode, MIDI needs a soundfont note")
    func media() throws {
        let (mv, c1) = try report("mv-basic"); defer { c1.close() }
        let intro = mv.descriptor.mediaRequirements.first { $0.sourceRel.hasSuffix("intro.webm") }
        #expect(intro?.action == .useSibling("www/movies/intro.mp4"))
        #expect(!mv.descriptor.warnings.contains {
            if case .mediaTranscodeRequired = $0 {
                true
            } else {
                false
            }
        })
        let (mz, c2) = try report("mz-basic"); defer { c2.close() }
        let mzIntro = mz.descriptor.mediaRequirements.first { $0.sourceRel.hasSuffix("intro.webm") }
        #expect(mzIntro?.action == .transcode(target: "mp4/h264/aac"))
        #expect(mz.descriptor.warnings.contains(.mediaTranscodeRequired(count: 1)))
        #expect(mz.descriptor.mediaRequirements.contains { $0.action == .shim("audioFileExtOgg") })
    }

    @Test("Save strategies exist for every supported family")
    func saves() {
        for f in [EngineFamily.rpgMakerMV, .rpgMakerMZ, .rpgMakerXP, .rpgMakerVXAce, .renpy, .rpgMaker2003, .godot, .html5] {
            #expect(SaveStrategy.forEngine(f, generation: nil).canManageSaves, "\(f)")
        }
        #expect(SaveStrategy.forEngine(.unityNative, generation: nil).family == .unknown)
        #expect(SaveStrategy.forEngine(.rpgMakerVXAce, generation: .rgss3).slotPattern == "Save%02d.rvdata2")
    }

    @Test("Explanations render for supported, unknown and refused fixtures; candidates are capped at four")
    func explain() throws {
        let (mz, c1) = try report("mz-nwplugin"); defer { c1.close() }
        #expect(DetectionExplainer.summary(mz).hasPrefix("Detected rpgMakerMZ 1.9.0, with"))
        let sections = DetectionExplainer.sections(mz)
        #expect(sections.contains { $0.title == "Plugins" && $0.lines.contains { $0.contains("NwFs") } })
        let (unity, c2) = try report("unity-native-il2cpp"); defer { c2.close() }
        #expect(DetectionExplainer.sections(unity).first?.title == "Why it cannot run")
        #expect(DetectionExplainer.summary(unity).contains("Unity 2022.3.20f1"))
        let (unknown, c3) = try report("unknown-min"); defer { c3.close() }
        #expect(DetectionExplainer.summary(unknown) == "Could not tell which engine this is.")
        var many = mz
        many.candidateRuntimes = (0 ..< 6).map { RuntimeCandidate(runtime: .web, confidence: 0.5, reason: "r\($0)") }
        #expect(DetectionExplainer.candidates(many).count == 4)
        #expect(DetectionExplainer.name(.rgss(ruby: .ruby19)) == "mkxp-z (Ruby 1.9)")
        #expect(DetectionExplainer.name(.renpy(engine: .v853)) == "Ren'Py 8.5.3")
    }
}
