import Foundation
import GameCore
@testable import OmniPlay
import SaveKit
import Testing

@Suite("Save transfer")
struct SaveTransferTests {
    private func paths() -> (AppPaths, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "transfer-\(UUID().uuidString)")
        return (
            AppPaths(root: root.appending(path: "S"), cachesRoot: root.appending(path: "C"), exportsRoot: root.appending(path: "E")),
            root
        )
    }

    private func target(_ paths: AppPaths, hash: String) -> SaveTransfer {
        SaveTransfer(
            paths: paths,
            target: .init(
                id: GameID(),
                title: "Dragon Quest",
                engine: .rpgMakerVXAce,
                family: .rgssMarshal,
                slotPattern: "Save%02d.rvdata2",
                identityHash: hash
            )
        )
    }

    @Test("Export produces a ZIP with a manifest; import into the same title stacks into free slots; a foreign title needs confirmation")
    func roundTrip() async throws {
        let (paths, root) = paths()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = target(paths, hash: "same")
        let store = SaveFileStore(location: source.location, fileExtension: "rvdata2")
        try store.write(Data([0x04, 0x08, 0x5B, 0x00]), key: "Save01")
        try store.write(Data([0x04, 0x08, 0x5B, 0x01]), key: "Save02")
        let zip = try await source.export()
        #expect(zip.pathExtension == "zip" && zip.lastPathComponent.hasPrefix("Dragon Quest-"))

        try store.write(Data([0x04, 0x08, 0x5B, 0x09]), key: "Save01")
        let stacked = try await source.importSaves(from: zip, collision: .nextFreeSlot, confirmed: false)
        #expect(stacked == .installed(slots: 2, persistent: 0))
        #expect(store.keys().map(\.key) == ["Save01", "Save02", "Save03", "Save04"])
        #expect(try store.read(key: "Save01") == Data([0x04, 0x08, 0x5B, 0x09]))

        let other = target(paths, hash: "other")
        let outcome = try await other.importSaves(from: zip, collision: .replace, confirmed: false)
        guard case let .needsConfirmation(warnings) = outcome else { Issue.record("expected confirmation, got \(outcome)"); return }
        #expect(warnings.contains { $0.contains("different game") })
        #expect(try await other.importSaves(from: zip, collision: .replace, confirmed: true) == .installed(slots: 2, persistent: 0))

        let junk = root.appending(path: "junk.rvdata2")
        try Data([0xDE, 0xAD]).write(to: junk)
        guard case .nothingRecognised = try await other.importSaves(from: junk, collision: .replace, confirmed: true)
        else { Issue.record("junk accepted"); return }
        #expect(SaveVault.snapshots(location: other.location).count == 1)
    }
}
