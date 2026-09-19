import Foundation
import GameCore
@testable import RuntimeCore
import SaveKit
import Testing
import TestSupport

@Suite("SaveBridge")
struct SaveBridgeTests {
    @Test("Writes land as files, bad keys are refused, and the seed round-trips both kinds")
    func roundTrip() throws {
        let root = try TemporaryGameRoot(name: "bridge")
        defer { root.remove() }
        let location = SaveLocation(savesRoot: root.url.appending(path: "Saves"))
        let bridge = SaveBridge(location: location, engine: .rpgMakerMV)
        bridge.handle(op: "write", kind: "ls", key: "RPG File1", value: "N4Ig")
        bridge.handle(op: "write", kind: "mz", key: "rmmzsave.1.file1", value: Data([0x78, 0x9C, 0x00]).base64EncodedString())
        bridge.handle(op: "write", kind: "mz", key: "../escape", value: "AA==")
        bridge.handle(op: "write", kind: "ls", key: "RPG File2", value: "gone")
        bridge.handle(op: "remove", kind: "ls", key: "RPG File2", value: nil)
        #expect(FileManager.default
            .fileExists(atPath: location.slots.appending(path: "ls.UlBHIEZpbGUx.rpgsave").path(percentEncoded: false)))
        #expect(try Data(contentsOf: location.slots.appending(path: "rmmzsave.1.file1.rmmzsave")) == Data([0x78, 0x9C, 0x00]))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: location.slots.path(percentEncoded: false)))?.count == 2)

        let seed = try JSONDecoder().decode([String: [String: String]].self, from: Data(bridge.seed().utf8))
        #expect(seed["ls"] == ["RPG File1": "N4Ig"])
        #expect(seed["mz"] == ["rmmzsave.1.file1": "eJwA"])
    }

    @Test("Storage script and bundle carry the seed placeholder and forward through DOM events")
    func scripts() throws {
        let storage = try WebRuntimeBundle.source("omniplay-storage", profile: WebProfile(), saves: #"{"ls":{"a":"b"}}"#)
        #expect(storage.contains(#"const saves = {"ls":{"a":"b"}};"#))
        #expect(!storage.contains("__OMNIPLAY_SAVES__"))
        let bootstrap = try WebRuntimeBundle.source("omniplay-bootstrap", profile: WebProfile())
        #expect(bootstrap.contains("omniplay:storage") && bootstrap.contains("omniplay:booted"))
        #expect(WebRuntimeBundle.pageScripts.first == "omniplay-storage")
    }
}
