import Foundation
import GameCore
import GameDetection
import GameImport
import Testing
import TestSupport

@Suite("Fixture detection", .serialized)
struct FixtureDetectionTests {
    struct Row: Sendable {
        let fixture: String
        let family: EngineFamily
        let generation: EngineGeneration?
        let version: String?
        let runtime: RuntimeIdentifier?
        let playable: Bool
    }

    static let rows: [Row] = [
        Row(fixture: "mv-basic", family: .rpgMakerMV, generation: .mv, version: "1.6.2", runtime: .web, playable: true),
        Row(fixture: "mv-encrypted", family: .rpgMakerMV, generation: .mv, version: "1.6.2", runtime: .web, playable: true),
        Row(fixture: "mz-basic", family: .rpgMakerMZ, generation: .mz, version: "1.9.0", runtime: .web, playable: true),
        Row(fixture: "mz-nwplugin", family: .rpgMakerMZ, generation: .mz, version: "1.9.0", runtime: .web, playable: true),
        Row(fixture: "html5-generic", family: .html5, generation: nil, version: nil, runtime: .web, playable: true),
        Row(fixture: "tyrano-min", family: .html5, generation: nil, version: nil, runtime: .web, playable: true),
        Row(fixture: "twine-min", family: .html5, generation: nil, version: nil, runtime: .web, playable: true),
        Row(fixture: "unity-web-min", family: .unityWeb, generation: nil, version: nil, runtime: .web, playable: true),
        Row(fixture: "godot-web-min", family: .godotWeb, generation: nil, version: nil, runtime: .web, playable: true),
        Row(fixture: "rgss-xp", family: .rpgMakerXP, generation: .rgss1, version: nil, runtime: .rgss(ruby: .ruby18), playable: true),
        Row(fixture: "rgss-vx", family: .rpgMakerVX, generation: .rgss2, version: nil, runtime: .rgss(ruby: .ruby18), playable: true),
        Row(fixture: "rgss-vxace", family: .rpgMakerVXAce, generation: .rgss3, version: nil, runtime: .rgss(ruby: .ruby19), playable: true),
        Row(
            fixture: "rgss-essentials-like",
            family: .rpgMakerVXAce,
            generation: .rgss3,
            version: nil,
            runtime: .rgss(ruby: .ruby31),
            playable: true
        ),
        Row(fixture: "renpy-7x", family: .renpy, generation: .renpyPy27, version: "7.8.7", runtime: nil, playable: true),
        Row(fixture: "renpy-81", family: .renpy, generation: .renpyPy39, version: "8.1.3", runtime: nil, playable: true),
        Row(fixture: "renpy-85", family: .renpy, generation: .renpyPy312, version: "8.5.3", runtime: nil, playable: true),
        Row(fixture: "rm2k3-min", family: .rpgMaker2000, generation: nil, version: nil, runtime: .easyrpg, playable: true),
        Row(fixture: "godot-47-min", family: .godot, generation: .godot4x, version: "4.7.2", runtime: .godot(bucket: .v47), playable: true),
        Row(fixture: "godot-3-min", family: .godot, generation: nil, version: "3.5.3", runtime: nil, playable: false),
        Row(
            fixture: "godot-gdextension",
            family: .godot,
            generation: .godot4x,
            version: "4.7.2",
            runtime: .godot(bucket: .v47),
            playable: false
        ),
        Row(
            fixture: "godot-encrypted",
            family: .godot,
            generation: .godot4x,
            version: "4.7.2",
            runtime: .godot(bucket: .v47),
            playable: false
        ),
        Row(fixture: "unity-native-il2cpp", family: .unityNative, generation: nil, version: nil, runtime: nil, playable: false),
        Row(fixture: "unity-native-mono", family: .unityNative, generation: nil, version: nil, runtime: nil, playable: false),
        Row(fixture: "unreal-min", family: .unreal, generation: nil, version: nil, runtime: nil, playable: false),
        Row(fixture: "gamemaker-min", family: .gameMaker, generation: nil, version: nil, runtime: nil, playable: false),
        Row(fixture: "wolf-min", family: .wolfRPG, generation: nil, version: nil, runtime: nil, playable: false),
        Row(fixture: "kirikiri-min", family: .kirikiri, generation: nil, version: nil, runtime: nil, playable: false),
        Row(fixture: "unknown-min", family: .unknown, generation: nil, version: nil, runtime: nil, playable: false),
    ]

    @Test("Every synthetic fixture resolves to the expected family, generation, version and first runtime", arguments: rows)
    func fixtures(row: Row) throws {
        let ctx = try ScanContext(root: Fixtures.url(row.fixture))
        defer { ctx.close() }
        let report = DetectionPipeline.standard.run(ctx, title: row.fixture, identityHash: "h")
        let d = report.descriptor
        #expect(d.engine == row.family, "engine \(d.engine) — \(report.evidence.map(\.explanation))")
        #expect(d.generation == row.generation, "generation \(String(describing: d.generation))")
        if let v = row.version {
            #expect(d.version?.raw.hasPrefix(v) == true, "version \(String(describing: d.version))")
        }
        if let rt = row.runtime {
            #expect(
                report.candidateRuntimes.first?.runtime == rt,
                "runtime \(String(describing: report.candidateRuntimes.first))"
            )
        }
        #expect(report.outcome.isPlayableClass == row.playable, "outcome \(report.outcome)")
        var again = DetectionPipeline.standard.run(ctx, id: d.id, title: row.fixture, identityHash: "h")
        var first = report
        first.descriptor.importedAt = Date(timeIntervalSince1970: 0)
        again.descriptor.importedAt = Date(timeIntervalSince1970: 0)
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let a = try enc.encode(first), b = try enc.encode(again)
        #expect(a == b, "two runs differ")
    }

    @Test("Specific facts: Unity version string, plugin warning, encryption, RTP, refusal messages")
    func specifics() throws {
        func report(_ f: String) throws -> DetectionReport {
            let ctx = try ScanContext(root: Fixtures.url(f))
            defer { ctx.close() }
            return DetectionPipeline.standard.run(ctx, title: f, identityHash: "h")
        }
        let unity = try report("unity-native-il2cpp")
        guard case let .refused(reason) = unity.outcome else { Issue.record("unity not refused"); return }
        #expect(reason.technicalDetail == "Unity 2022.3.20f1 IL2CPP Windows x86")
        let plugin = try report("mz-nwplugin")
        let pluginWarning = plugin.descriptor.warnings.first {
            if case .nodePlugin = $0 {
                true
            } else {
                false
            }
        }
        guard case let .nodePlugin(file, apis)? = pluginWarning
        else { Issue.record("no plugin warning: \(plugin.descriptor.warnings)"); return }
        #expect(file.hasSuffix("NwFs.js"))
        #expect(apis.contains("require('fs'"))
        guard case let .supportedWithLimitations(lims) = plugin.outcome else { Issue.record("plugin outcome \(plugin.outcome)"); return }
        #expect(lims.contains(.nodePlugins(1)))
        let enc = try report("mv-encrypted")
        #expect(enc.descriptor.profile.overrides["encryptedAssets"] == "true")
        #expect(enc.descriptor.title == "Synthetic MV")
        #expect(enc.descriptor.entryPoint == "www/index.html")
        let xp = try report("rgss-xp")
        #expect(xp.descriptor.warnings.contains {
            if case .rtpRequired = $0 {
                true
            } else {
                false
            }
        })
        #expect(xp.descriptor.saveFamily == .rgssMarshal)
        let gd = try report("godot-encrypted")
        #expect(gd.descriptor.blockers.contains(.encryptedPCK))
        let three = try report("godot-3-min")
        guard case let .unsupported(why) = three.outcome else { Issue.record("godot 3 outcome \(three.outcome)"); return }
        #expect(why.contains("Godot 3.5.3"))
        let tyrano = try report("tyrano-min")
        #expect(tyrano.descriptor.profile.overrides["webSubFamily"] == "tyrano")
        let generic = try report("html5-generic")
        #expect(generic.outcome == .experimental)
    }
}
