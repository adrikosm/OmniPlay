import Foundation
import GameCore
@testable import GameDetection
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
        Row(fixture: "rm2k3-min", family: .rpgMaker2003, generation: nil, version: nil, runtime: .easyrpg, playable: true),
        // Shipped as 2003: an exe beside PNG charsets was read as the 2003 signature (EasyRPG's TestGame-2000).
        Row(fixture: "rm2k-min", family: .rpgMaker2000, generation: nil, version: nil, runtime: .easyrpg, playable: true),
        Row(fixture: "zcode-min", family: .scummvm, generation: nil, version: nil, runtime: .scummvm, playable: true),
        Row(fixture: "ags-min", family: .scummvm, generation: nil, version: nil, runtime: .scummvm, playable: true),
        Row(fixture: "godot-47-min", family: .godot, generation: .godot4x, version: "4.7.2", runtime: .godot(bucket: .v47), playable: true),
        Row(fixture: "godot-3-min", family: .godot, generation: .godot3x, version: "3.5.3", runtime: .godot(bucket: .v36), playable: true),
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

    /// The table is the product: every supported engine family, its generation and the runtime it
    /// lands on, checked against a real fixture tree and asserted to be deterministic across runs.
    @Test("Every synthetic fixture resolves to the expected family, generation, version and first runtime")
    func fixtures() throws {
        for row in Self.rows {
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
        /// XP3 lengths come from untrusted bytes, including values that used to overflow signed addition.
        func chunk(_ tag: String, _ size: UInt64, _ body: Data = Data()) -> Data {
            var length = size.littleEndian
            return Data(tag.utf8) + withUnsafeBytes(of: &length) { Data($0) } + body
        }
        for size in [UInt64(Int.max), UInt64.max, 1] {
            #expect(KiriKiriDetector.entries(in: chunk("File", size)).isEmpty)
            #expect(KiriKiriDetector.entries(in: chunk("File", 12, chunk("info", size))).isEmpty)
        }
        let root = try TemporaryGameRoot(name: "xp3-lengths")
        defer { root.remove() }
        var offset = UInt64.max.littleEndian
        let archive = try root.file("bad.xp3", Data(KiriKiriDetector.magicBytes) + withUnsafeBytes(of: &offset) { Data($0) })
        #expect(KiriKiriDetector.index(of: archive) == nil)
        #expect(KiriKiriDetector.inflate(Data(repeating: 0, count: 8), expected: 0) == nil)
    }
}
