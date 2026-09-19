import Foundation
import GameCore
import GameImport
import Testing
import TestSupport

@Suite("Game root locator", .serialized)
struct GameRootLocatorTests {
    private func staged(_ archive: String) throws -> (URL, TemporaryGameRoot) {
        let root = try TemporaryGameRoot(name: "root")
        let out = root.url.appending(path: "Original")
        _ = try LibArchiveExtractor().extract(Fixtures.url(archive), to: out)
        return (out, root)
    }

    @Test("A single top folder collapses and junk disappears")
    func collapse() throws {
        let root = try TemporaryGameRoot(name: "collapse")
        try root.file("Original/GameFolder/Game.ini")
        try root.file("Original/GameFolder/Data/Map001.rxdata")
        try root.file("Original/__MACOSX/._Game.ini")
        try root.file("Original/GameFolder/.DS_Store")
        let located = try GameRootLocator.locate(stagingRoot: root.url.appending(path: "Original"))
        #expect(located.relativePath == "GameFolder")
        #expect(located.strippedItems.sorted() == ["GameFolder/.DS_Store", "__MACOSX"])
        #expect(!FileManager.default.fileExists(atPath: root.url.appending(path: "Original/__MACOSX").path(percentEncoded: false)))
    }

    @Test("A nested zip beside a readme is found for unwrapping; the extracted zip's folder is the root")
    func nested() throws {
        let (out, root) = try staged("mv-basic-nested.zip")
        defer { root.remove() }
        let inner = GameRootLocator.nestedArchive(in: out)
        #expect(inner?.lastPathComponent == "mv-basic.zip")
        let out2 = root.url.appending(path: "Original-2")
        _ = try LibArchiveExtractor().extract(#require(inner), to: out2)
        let located = try GameRootLocator.locate(stagingRoot: out2)
        #expect(located.relativePath == "mv-basic")
        #expect(GameRootLocator.nestedArchive(in: Fixtures.url("mv-basic")) == nil)
    }

    @Test("APK assets with x- prefixes become assets/game and the root is assets")
    func apk() throws {
        let (out, root) = try staged("renpy-apk-min.apk")
        defer { root.remove() }
        let located = try GameRootLocator.locate(stagingRoot: out)
        #expect(located.relativePath == "assets")
        #expect(FileManager.default.fileExists(atPath: out.appending(path: "assets/game/script.rpyc").path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: out.appending(path: "assets/private.mp3").path(percentEncoded: false)))
        #expect(located.sidecars.notes.first?.contains("APK") == true)
    }

    @Test(".jgp sidecars are captured and removed from the tree")
    func jgp() throws {
        let (out, root) = try staged("mv.jgp")
        defer { root.remove() }
        let located = try GameRootLocator.locate(stagingRoot: out)
        #expect(located.sidecars.files.keys.sorted() == ["configuration.json", "gamepad.json", "manifest.json"])
        #expect(located.sidecars.files["manifest.json"]?.contains("Synthetic MV") == true)
        #expect(!FileManager.default.fileExists(atPath: out.appending(path: "manifest.json").path(percentEncoded: false)))
        #expect(located.relativePath == "www") // the package left only www/, which collapses like any single folder
    }

    @Test("An .app bundle resolves to Contents/Resources/autorun")
    func appBundle() throws {
        let root = try TemporaryGameRoot(name: "app")
        try root.file("Original/Story.app/Contents/Resources/autorun/renpy/__init__.py")
        try root.file("Original/Story.app/Contents/MacOS/Story")
        let located = try GameRootLocator.locate(stagingRoot: root.url.appending(path: "Original"))
        #expect(located.relativePath == "Story.app/Contents/Resources/autorun")
    }

    @Test("Two plausible game folders raise multipleRoots")
    func multiple() throws {
        let root = try TemporaryGameRoot(name: "multi")
        try root.file("Original/A/Game.ini")
        try root.file("Original/B/index.html")
        do {
            _ = try GameRootLocator.locate(stagingRoot: root.url.appending(path: "Original"))
            Issue.record("no multipleRoots")
        } catch let ImportFailure.multipleRoots(c) { #expect(c.sorted() == ["A", "B"]) }
        #expect(try GameRootLocator.locate(stagingRoot: root.url.appending(path: "Original"), chosen: "B").relativePath == "B")
        #expect(throws: ImportFailure.self) { try GameRootLocator.locate(stagingRoot: root.url.appending(path: "Original"), chosen: "Nope")
        }
    }
}

@Suite("PE overlay scanner")
struct PEOverlayScannerTests {
    @Test("NW.js style appended zip is located and extracts in place")
    func appendedZip() throws {
        let payload = try PEOverlayScanner.scan(Fixtures.url("nwjs-appended.exe"))
        #expect(payload?.overlayOffset == 0x400)
        #expect(payload?.machine == .x86)
        guard case let .appendedZip(offset)? = payload?.kind else { Issue.record("kind \(String(describing: payload?.kind))"); return }
        #expect(offset == 0x400)
        let root = try TemporaryGameRoot(name: "nw")
        let totals = try LibArchiveExtractor().extract(
            Fixtures.url("nwjs-appended.exe"),
            to: root.url.appending(path: "out"),
            offset: offset
        )
        #expect(totals.entries == 3)
        let core = try String(contentsOf: root.url.appending(path: "out/www/js/rpg_core.js"), encoding: .utf8)
        #expect(core.contains("1.6.2"))
        let pre = try LibArchiveExtractor().preflight(Fixtures.url("nwjs-appended.exe"), offset: offset)
        #expect(pre.entries == 3)
    }

    @Test("Godot embedded PCK tail is located with offset and size")
    func godot() throws {
        let payload = try PEOverlayScanner.scan(Fixtures.url("godot-embedded.exe"))
        guard case let .godotPCK(offset, size)? = payload?.kind else { Issue.record("kind \(String(describing: payload?.kind))"); return }
        #expect(offset == 0x400)
        let header = try BoundedReader.readHeader(url: Fixtures.url("godot-embedded.exe"), bytes: Int(offset) + 4)
        #expect(header.suffix(4).elementsEqual("GDPC".utf8))
        #expect(size > 0)
    }

    @Test("A plain PE stub has no payload; a truncated or non-PE file is not a PE")
    func plainAndBroken() throws {
        let plain = try PEOverlayScanner.scan(Fixtures.url("rgss-xp/Game.exe"))
        #expect(plain?.kind == PEPayload.Kind.none)
        #expect(plain?.sectionNames == [".text"])
        #expect(try PEOverlayScanner.scan(Fixtures.url("mv-basic.zip")) == nil)
        let root = try TemporaryGameRoot(name: "trunc")
        let truncated = try root.file("t.exe", Data(contentsOf: Fixtures.url("rgss-xp/Game.exe")).prefix(0x300))
        #expect(try PEOverlayScanner.scan(truncated) == nil)
    }
}

@Suite("Names and fingerprints")
struct NameAndFingerprintTests {
    @Test("CP932 archives get a charset; UTF-8 archives none")
    func charset() throws {
        let x = LibArchiveExtractor()
        #expect(try NameDecoder.charset(for: Fixtures.url("shiftjis-names.zip"), extractor: x) == "CP932")
        #expect(try NameDecoder.charset(for: Fixtures.url("mv-basic.zip"), extractor: x) == nil)
    }

    @Test("Folder fingerprints are stable, order-independent and change with content layout")
    func fingerprint() throws {
        let a = try SourceFingerprint.compute(Fixtures.url("mv-basic"))
        #expect(try a == (SourceFingerprint.compute(Fixtures.url("mv-basic"))))
        #expect(a.hasPrefix("folder-"))
        #expect(try a != (SourceFingerprint.compute(Fixtures.url("mz-basic"))))
        let zip = try SourceFingerprint.compute(Fixtures.url("mv-basic.zip"))
        #expect(zip.count == 64)
    }
}
