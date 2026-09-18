import Foundation
import GameCore
import GameDetection
import Testing

@Suite("RGSS archive signature")
struct RGSSArchiveSignatureTests {
    private func header(_ version: UInt8) -> Data { Data("RGSSAD".utf8) + Data([0, version]) }

    @Test("Parses v1 and v3 headers, rejects everything else")
    func headerParsing() {
        #expect(RGSSArchiveHeader(prefix: header(1))?.version == .v1)
        #expect(RGSSArchiveHeader(prefix: header(3))?.version == .v3)
        #expect(RGSSArchiveHeader(prefix: header(2)) == nil)
        #expect(RGSSArchiveHeader(prefix: Data("RGSSAD".utf8)) == nil) // too short
        #expect(RGSSArchiveHeader(prefix: Data("PK\u{03}\u{04}xxxx".utf8)) == nil)
    }

    @Test("Header + extension → exact engine", arguments: [
        (UInt8(1), "Game.rgssad", EngineFamily.rpgMakerXP),
        (UInt8(1), "Game.rgss2a", EngineFamily.rpgMakerVX),
        (UInt8(3), "Game.rgss3a", EngineFamily.rpgMakerVXAce),
    ])
    func exactMatch(version: UInt8, file: String, engine: EngineFamily) throws {
        let tree = InMemoryGameTree(files: [file: header(version) + Data(repeating: 0, count: 64)])
        let result = try RGSSArchiveSignature().evaluate(tree)
        #expect(result?.engine == engine)
        #expect(result?.gate == .automatic)
    }

    @Test("Header/extension disagreement falls back to the header with a warn-level confidence")
    func mismatchWarns() throws {
        let tree = InMemoryGameTree(files: ["Game.rgssad": header(3)])
        let result = try RGSSArchiveSignature().evaluate(tree)
        #expect(result?.engine == .rpgMakerVXAce)
        #expect(result?.gate == .warn)
    }

    @Test("No RGSS archive → no result, so later signatures run")
    func noArchive() throws {
        let tree = InMemoryGameTree(files: ["js/rmmz_core.js": Data(), "index.html": Data()])
        #expect(try RGSSArchiveSignature().evaluate(tree) == nil)
    }

    @Test("Confidence gates follow §17")
    func gates() {
        #expect(ConfidenceGate(confidence: 0.95) == .automatic)
        #expect(ConfidenceGate(confidence: 0.90) == .automatic)
        #expect(ConfidenceGate(confidence: 0.75) == .warn)
        #expect(ConfidenceGate(confidence: 0.59) == .manualPicker)
    }
}
