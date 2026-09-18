import Foundation
import GameCore
import Testing

@Suite("GameCore models")
struct GameCoreTests {
    @Test("Every enum round-trips through JSON")
    func enumsCodable() throws {
        func roundTrip<T: Codable & Equatable>(_ values: [T]) throws {
            for v in values {
                #expect(try JSONDecoder().decode(T.self, from: JSONEncoder().encode(v)) == v)
            }
        }
        try roundTrip(EngineFamily.allCases)
        try roundTrip(EngineGeneration.allCases)
        try roundTrip(SessionSlot.allCases)
        try roundTrip(ContentTier.allCases)
        try roundTrip(ContentKind.allCases)
        try roundTrip(PlayabilityGrade.allCases)
        try roundTrip([RuntimeIdentifier.web, .rgss(ruby: .ruby18), .renpy(engine: .v853), .godot(bucket: .v47), .tic80])
        try roundTrip([EngineVersion(major: 1, minor: 6, patch: 2), #require(EngineVersion(parsing: "v4.7.2-stable"))])
    }

    @Test("Engine versions parse and compare")
    func versions() {
        #expect(EngineVersion(parsing: "8.1.3.23090501") == EngineVersion(major: 8, minor: 1, patch: 3, raw: "8.1.3.23090501"))
        #expect(EngineVersion(parsing: "Utils.RPGMAKER_VERSION = \"1.6.2\"")?.patch == 2)
        #expect(EngineVersion(parsing: "none") == nil)
        #expect(EngineVersion(major: 7, minor: 8, patch: 7) < EngineVersion(major: 8))
    }

    @Test("Runtime identifiers map to declared slots")
    func slots() {
        #expect(RuntimeIdentifier.rgss(ruby: .ruby31).slot == .ruby31)
        #expect(RuntimeIdentifier.renpy(engine: .v787).slot == .renpy787)
        #expect(SessionSlot.web.sessionsPerProcess == .unlimited)
        #expect(SessionSlot.renpy853.sessionsPerProcess == .oneWithSoftRestart)
        #expect(SessionSlot.easyrpg.sessionsPerProcess == .one)
        #expect(SessionSlot.allCases.count == 14)
    }

    @Test("Engine families carry eligibility tiers")
    func tiers() {
        #expect(EngineFamily.rpgMakerMZ.tier == .core)
        #expect(EngineFamily.godot.tier == .opportunistic)
        #expect(EngineFamily.wolfRPG.tier == .refused)
        #expect(EngineFamily.unknown.tier == .refused)
    }

    @Test("Every content kind maps to exactly one tier and a writer")
    func ownership() {
        #expect(ContentKind.modOverride.ownership.tier == .overrides)
        #expect(ContentKind.saveFile.ownership.exportable)
        #expect(!ContentKind.originalGame.ownership.exportable)
        #expect(Set(ContentKind.allCases.map(\.ownership.tier)).count == 7)
    }

    @Test("Storage layout composes the §15.2 tree and is idempotent")
    func appPaths() throws {
        let paths = AppPaths.temporary()
        let game = GameID()
        #expect(paths.tier(.original, for: game).pathComponents.suffix(3) == ["Games", game.description, "Original"])
        #expect(paths.path(for: .modOverride, game: game).lastPathComponent == "mods")
        #expect(paths.tier(.persistent, for: game).path().hasSuffix("Saves/persistent/"))
        #expect(paths.logs(game: nil, session: UUID()).pathComponents.contains("host"))
        #expect(paths.database().lastPathComponent == "omniplay.sqlite")
        try paths.ensureLayout()
        try paths.ensureLayout()
        #expect(FileManager.default.fileExists(atPath: paths.rtp(.vxAce).path()))
        #expect(try paths.games().resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        try? FileManager.default.removeItem(at: paths.root.deletingLastPathComponent())
    }

    @Test("SmallFileGuard reads below the cap and throws above it")
    func smallFileGuard() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "guard-\(UUID().uuidString).bin")
        try Data(repeating: 7, count: 1024).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try SmallFileGuard.read(url).count == 1024)
        #expect(throws: FileTooLargeError.self) { try SmallFileGuard.read(url, maxBytes: 100) }
    }

    @Test("Playability grades are ordered")
    func grades() {
        #expect(PlayabilityGrade.refused < PlayabilityGrade.playable)
    }

    @Test("Game descriptors round-trip through JSON")
    func descriptorCodable() throws {
        let d = GameDescriptor(
            title: "Fixture",
            engine: .renpy,
            version: EngineVersion(parsing: "8.5.3"),
            runtimeCandidates: [.renpy(engine: .v853)],
            evidence: [.init(check: "x", outcome: "y", weight: 1)],
            identityHash: "abc"
        )
        #expect(try JSONDecoder().decode(GameDescriptor.self, from: JSONEncoder().encode(d)) == d)
    }
}
