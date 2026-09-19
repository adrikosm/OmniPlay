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
        for name in WebRuntimeBundle.pageScripts + WebRuntimeBundle.isolatedScripts {
            #expect(try !(WebRuntimeBundle.source(name, profile: WebProfile())).isEmpty, Comment(rawValue: name))
        }
    }

    @Test("Input batches encode DOM key names, legacy keyCodes and gamepad fields")
    func inputEncoding() throws {
        let json = WebInputEncoder.json([.keyDown(.keyZ), .controllerAxis(.leftY, value: 0.5), .pointerDown(.secondary, x: 10, y: 20)])
        let items = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        #expect(items?.count == 3)
        #expect(items?[0]["code"] as? String == "KeyZ" && items?[0]["key"] as? String == "z" && items?[0]["keyCode"] as? Int == 90)
        #expect(items?[1]["axis"] as? String == "leftY" && items?[1]["value"] as? Double == 0.5)
        #expect(items?[2]["button"] as? String == "secondary" && items?[2]["phase"] as? String == "down")
    }
}

@Suite("MediaPlan")
struct MediaPlanTests {
    private func req(_ src: String, _ action: MediaRequirement.Action) -> MediaRequirement {
        MediaRequirement(sourceRel: src, container: "webm", videoCodec: "vp9", audioCodec: "opus", requiredForRuntime: .web, action: action)
    }

    @Test("Extension-changing siblings need no alias; same-extension siblings do; transcodes are pending")
    func plan() {
        let plan = MediaPlan(requirements: [
            req("movies/intro.webm", .useSibling("movies/intro.mp4")),
            req("movies/mp4/end.mp4", .useSibling("movies/alt/end.mp4")),
            req("movies/boss.webm", .transcode(target: "mp4/h264/aac")),
            req("audio/bgm/a.ogg", .shim("audioFileExtOgg")),
        ])
        #expect(plan.aliases == ["movies/mp4/end.mp4": "movies/alt/end.mp4"])
        #expect(plan.pendingTranscodes.map(\.sourceRel) == ["movies/boss.webm"])
        #expect(plan.notice == "One video needs converting and may not play yet.")
        #expect(MediaPlan(requirements: []).notice == nil)
    }
}
