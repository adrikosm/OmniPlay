import Foundation
import GameCore
import Testing

@Suite("GameCore")
struct GameCoreTests {
    @Test("Overlay resolution order is Overrides → Generated → Original → RTP")
    func resolutionOrder() {
        #expect(ResolutionTier.resolutionOrder == [.overrides, .generated, .original, .rtp])
        #expect(ResolutionTier.overrides < ResolutionTier.rtp)
    }

    @Test("Storage layout composes the §15.2 tree")
    func storageLayout() {
        let layout = StorageLayout(root: URL(filePath: "/tmp/OmniPlay", directoryHint: .isDirectory))
        let gameID = UUID()
        let game = layout.game(gameID)
        #expect(game.original.lastPathComponent == "Original")
        #expect(game.saves.lastPathComponent == "Saves")
        #expect(game.root.lastPathComponent == gameID.uuidString)
        #expect(layout.databaseFile.lastPathComponent == "omniplay.sqlite")
        #expect(layout.rtp(.vxAce).lastPathComponent == "VXAce")
        #expect(layout.requiredDirectories.count == 7 + RTPFamily.allCases.count)
    }

    @Test("Game directories map tiers to folders")
    func tierDirectories() {
        let game = GameDirectories(root: URL(filePath: "/tmp/g", directoryHint: .isDirectory))
        #expect(game.directory(for: .overrides) == game.overrides)
        #expect(game.directory(for: .rtp) == nil)
        #expect(game.directory(for: .rtp, rtp: URL(filePath: "/tmp/rtp"))?.lastPathComponent == "rtp")
    }

    @Test("Playability grades are ordered")
    func gradesOrdered() {
        #expect(PlayabilityGrade.refused < PlayabilityGrade.playable)
        #expect(PlayabilityGrade.allCases.count == 6)
    }

    @Test("Every engine family has a tier and refused families are named")
    func engineTiers() {
        #expect(EngineFamily.rpgMakerMZ.tier == .core)
        #expect(EngineFamily.scummvm.tier == .breadth)
        #expect(EngineFamily.godot.tier == .opportunistic)
        #expect(EngineFamily.unityNative.tier == .refused)
        #expect(EngineFamily.unknown.tier == .refused)
    }

    @Test("Game descriptors round-trip through JSON")
    func descriptorCodable() throws {
        let descriptor = GameDescriptor(title: "Fixture", engine: .renpy, engineVersion: "8.5.3", identityHash: "abc")
        let data = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(GameDescriptor.self, from: data)
        #expect(decoded == descriptor)
    }
}
