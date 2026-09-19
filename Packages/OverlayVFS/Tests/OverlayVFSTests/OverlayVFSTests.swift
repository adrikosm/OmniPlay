import Foundation
import GameCore
import OverlayVFS
import Testing
import TestSupport

@Suite("Path index")
struct PathIndexTests {
    @Test("Mixed-case trees resolve case-insensitively; keys are NFC and slash-normalised")
    func lookup() throws {
        let root = try TemporaryGameRoot(name: "idx")
        try root.file("Original/Graphics/Pictures/Actor1.png", Data([1]))
        try root.file("Original/Data/Map001.rxdata", Data([1, 2]))
        try root.file("Original/Audio/BGM/e\u{0301}.ogg")
        let index = try PathIndex.open(at: root.url.appending(path: "index.sqlite"))
        try index.build(layer: "original", root: root.url.appending(path: "Original"))
        let hit = try index.lookup(layer: "original", key: PathKey.normalize("graphics\\pictures\\ACTOR1.PNG"))
        #expect(hit?.realRel == "Graphics/Pictures/Actor1.png")
        #expect(hit?.size == 1)
        #expect(try index.lookup(layer: "original", key: PathKey.normalize("Audio/BGM/\u{00E9}.ogg")) != nil)
        #expect(try index.lookup(layer: "original", key: "data")?.isDir == true)
        #expect(try index.lookup(layer: "original", key: "missing") == nil)
        #expect(try index.count(layer: "original") == 8) // 3 files + 5 directories
        #expect(try index.children(layer: "original", directoryKey: "").map(\.key).sorted() == ["audio", "data", "graphics"])
        #expect(try index.children(layer: "original", directoryKey: "graphics").map(\.key) == ["graphics/pictures"])
    }

    @Test("Case-only collisions keep the first entry and are recorded; rebuild is idempotent")
    func collisions() throws {
        // The Mac's APFS is case-insensitive, so the two spellings come from two roots fed into one layer;
        // on the phone they can coexist in one directory and take the same path through `build`.
        let root = try TemporaryGameRoot(name: "coll")
        try root.file("Original/a.txt", Data([1]))
        try root.file("Original/b.txt")
        try root.file("Other/A.txt", Data([2]))
        let index = try PathIndex.open(at: root.url.appending(path: "index.sqlite"))
        try index.build(layer: "original", root: root.url.appending(path: "Original"))
        try index.build(layer: "original", root: root.url.appending(path: "Other"))
        let c = try index.collisions(layer: "original")
        #expect(c.count == 1)
        #expect(c.first?.keptReal == "a.txt")
        #expect(c.first?.droppedReal == "A.txt")
        #expect(try index.lookup(layer: "original", key: "a.txt")?.size == 1)
        #expect(try index.count(layer: "original") == 2)
        try index.rebuild(layer: "original", root: root.url.appending(path: "Original"))
        try index.rebuild(layer: "original", root: root.url.appending(path: "Original"))
        #expect(try index.count(layer: "original") == 2)
        #expect(try index.collisions(layer: "original").isEmpty) // rebuild starts from a clean layer
        try index.upsert(layer: "generated", relativePath: "Movies/x.mp4", isDirectory: false, size: 9)
        #expect(try index.layers() == ["generated", "original"])
        try index.remove(layer: "generated", relativePath: "movies/X.MP4")
        #expect(try index.count(layer: "generated") == 0)
    }

    @Test("A corrupt index file is replaced")
    func corrupt() throws {
        let root = try TemporaryGameRoot(name: "corrupt")
        let url = try root.file("index.sqlite", Data("not a database".utf8))
        let index = try PathIndex.open(at: url)
        #expect(try index.layers().isEmpty)
    }
}

@Suite("Overlay resolver")
struct OverlayResolverTests {
    private struct Game { let root: TemporaryGameRoot, paths: AppPaths, descriptor: GameDescriptor }
    private func makeGame() throws -> Game {
        let root = try TemporaryGameRoot(name: "ovl")
        let paths = AppPaths(
            root: root.url.appending(path: "Support"),
            cachesRoot: root.url.appending(path: "Caches"),
            exportsRoot: root.url.appending(path: "Export")
        )
        let game = GameDescriptor(title: "T", engine: .rpgMakerXP, identityHash: "h")
        try paths.ensureLayout()
        return Game(root: root, paths: paths, descriptor: game)
    }

    @Test("Resolution order is Overrides → Generated → Original → RTP, with ordered sub-layers under Overrides")
    func order() async throws {
        let g = try makeGame()
        let (root, paths, game) = (g.root, g.paths, g.descriptor)
        let id = game.id
        func put(_ tier: ContentTier, _ rel: String, _ byte: UInt8) throws {
            let url = paths.tier(tier, for: id).appending(path: rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([byte]).write(to: url)
        }
        try put(.original, "Graphics/Title.png", 1)
        try put(.original, "Graphics/Only.png", 1)
        try put(.generated, "Graphics/Title.png", 2)
        try put(.generated, "Movies/intro.mp4", 2)
        try put(.overrides, "mods/low/Graphics/Title.png", 3)
        try put(.overrides, "mods/high/Graphics/Title.png", 4)
        try Data([5]).write(to: { let u = paths.rtp(.xp).appending(path: "Graphics/RTPOnly.png"); try FileManager.default.createDirectory(
            at: u.deletingLastPathComponent(),
            withIntermediateDirectories: true
        ); return u }())
        let overlays = [
            OverlaySublayer(name: "mods/low", relativeDirectory: "mods/low", priority: 1),
            OverlaySublayer(name: "mods/high", relativeDirectory: "mods/high", priority: 2),
        ]
        let index = try PathIndex.open(at: paths.game(id).appending(path: "index.sqlite"))
        let resolver = OverlayResolver(layers: LayerSetBuilder.forGame(game, paths: paths, enabledOverlays: overlays), index: index)
        try resolver.indexAll()
        #expect(resolver.layers.map(\.name) == [
            "overrides/host",
            "overrides/mods/high",
            "overrides/mods/low",
            "generated",
            "original",
            "rtp",
        ])
        #expect(try Data(contentsOf: #require(resolver.resolve("graphics/title.PNG")?.url)) == Data([4]))
        #expect(resolver.resolve("Graphics\\Only.png")?.layer.tier == .original)
        #expect(resolver.resolve("movies/INTRO.mp4")?.layer.tier == .generated)
        #expect(resolver.resolve("Graphics/RTPOnly.png")?.layer.tier == .rtp)
        #expect(resolver.resolve("Graphics/Nope.png") == nil)
        let aliased = OverlayResolver(
            layers: resolver.layers,
            index: index,
            aliases: ["Movies/alt/intro.mp4": "Movies/intro.mp4", "../evil": "Graphics/Title.png", "Graphics/Loop.png": "Graphics/Loop.png"]
        )
        #expect(aliased.aliases.count == 1)
        #expect(aliased.resolve("movies/ALT/intro.mp4")?.layer.tier == .generated)
        #expect(aliased.resolve("Graphics/Loop.png") == nil)
        var listed: [String: ContentTier] = [:]
        for await entry in resolver.list(directory: "Graphics") {
            listed[entry.realRelativePath] = entry.layer.tier
        }
        #expect(listed == ["Graphics/Title.png": .overrides, "Graphics/Only.png": .original, "Graphics/RTPOnly.png": .rtp])
        var top: [String] = []
        for await entry in resolver.list(directory: "") {
            top.append(entry.realRelativePath)
        }
        #expect(Set(top) == ["Graphics", "Movies"])
        _ = root
    }

    @Test("Writable URLs exist only for Overrides, Generated and Saves and are indexed at once")
    func writable() throws {
        let g = try makeGame()
        let (root, paths, game) = (g.root, g.paths, g.descriptor)
        let index = try PathIndex.open(at: paths.game(game.id).appending(path: "index.sqlite"))
        var layers = LayerSetBuilder.forGame(game, paths: paths)
        layers.append(OverlayLayer(tier: .saves, root: paths.tier(.saves, for: game.id), name: "saves", priority: 0))
        let resolver = OverlayResolver(layers: layers, index: index)
        #expect(throws: OverlayError.readOnlyTier(.original)) { try resolver.writableURL("Data/x.rxdata", in: .original) }
        #expect(throws: OverlayError.readOnlyTier(.rtp)) { try resolver.writableURL("x", in: .rtp) }
        #expect(throws: OverlayError.invalidPath("../x")) { try resolver.writableURL("../x", in: .generated) }
        let url = try resolver.writableURL("Movies/Intro.mp4", in: .generated)
        try Data([9]).write(to: url)
        #expect(resolver.resolve("movies/intro.MP4")?.layer.tier == .generated)
        let save = try resolver.writableURL("Save01.rxdata", in: .saves)
        #expect(save.path(percentEncoded: false).contains("/Saves/"))
        _ = root
    }

    @Test("Path policy rejects traversal, absolute, dot and control-character paths")
    func policy() {
        #expect(PathPolicy.validateLogical("Graphics/Title.png") == "graphics/title.png")
        #expect(PathPolicy.validateLogical("a\\b//c") == "a/b/c")
        for bad in ["../x", "a/../b", "/abs", "\\abs", "a/./b", "a\u{0}b", "a\nb", "", "..", "."] {
            #expect(PathPolicy.validateLogical(bad) == nil, "\(bad.debugDescription) should be rejected")
        }
    }

    @Test("Layer sets add an RTP layer only for engines that use one")
    func layerSets() throws {
        let paths = try makeGame().paths
        let xp = LayerSetBuilder.forGame(GameDescriptor(title: "x", engine: .rpgMakerXP, identityHash: "h"), paths: paths)
        #expect(xp.last?.tier == .rtp)
        #expect(xp.last?.root == paths.rtp(.xp))
        let web = LayerSetBuilder.forGame(GameDescriptor(title: "w", engine: .html5, identityHash: "h"), paths: paths)
        #expect(!web.contains { $0.tier == .rtp })
        #expect(web.map(\.priority) == web.map(\.priority).sorted(by: >))
    }
}

@Suite("Original guard", .serialized)
struct OriginalGuardTests {
    @Test("Sealed originals refuse writes and the manifest matches the files")
    func seal() async throws {
        let root = try TemporaryGameRoot(name: "seal")
        let original = root.url.appending(path: "Original")
        try root.file("Original/Data/Map001.rxdata", Data("map".utf8))
        try root.file("Original/Graphics/Title.png", Data("png".utf8))
        let manifest = root.url.appending(path: "original.manifest")
        defer { try? OriginalGuard.unseal(originalRoot: original) }
        #expect(!OriginalGuard.isSealed(manifest: manifest))
        let summary = try OriginalGuard.seal(originalRoot: original, manifest: manifest)
        #expect(summary.files == 2 && summary.bytes == 6 && summary.hashed)
        #expect(OriginalGuard.isSealed(manifest: manifest))
        #expect(throws: (any Error).self) { try Data("x".utf8).write(to: original.appending(path: "Data/Map001.rxdata")) }
        #expect(throws: (any Error).self) { try Data("x".utf8).write(to: original.appending(path: "Data/New.rxdata")) }
        #expect(throws: (any Error).self) { try FileManager.default.removeItem(at: original.appending(path: "Graphics/Title.png")) }
        let lines = try String(contentsOf: manifest, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(try lines
            .contains("3\t\(StreamingHasher.sha256(of: original.appending(path: "Data/Map001.rxdata")).hex)\tData/Map001.rxdata"))
        let verdict = try await OriginalGuard.verify(originalRoot: original, manifest: manifest)
        #expect(verdict.ok && verdict.checked == 2)
        // Tamper after unsealing: verification must notice.
        try OriginalGuard.unseal(originalRoot: original)
        try Data("bad".utf8).write(to: original.appending(path: "Graphics/Title.png"))
        #expect(try await OriginalGuard.verify(originalRoot: original, manifest: manifest).mismatched == ["Graphics/Title.png"])
    }

    @Test("Deferred hashing writes placeholders that verify skips until completed")
    func deferred() async throws {
        let root = try TemporaryGameRoot(name: "deferred")
        let original = root.url.appending(path: "Original")
        try root.file("Original/a.bin", Data([1, 2, 3]))
        try root.file("Original/b.bin", Data([4]))
        let manifest = root.url.appending(path: "original.manifest")
        defer { try? OriginalGuard.unseal(originalRoot: original) }
        let summary = try OriginalGuard.seal(originalRoot: original, manifest: manifest, hashing: .deferred)
        #expect(!summary.hashed)
        #expect(try String(contentsOf: manifest, encoding: .utf8).contains("\t-\t"))
        let before = try await OriginalGuard.verify(originalRoot: original, manifest: manifest)
        #expect(before.checked == 0 && before.skippedUnhashed == 2)
        try await OriginalGuard.completeDeferredHashing(originalRoot: original, manifest: manifest)
        let after = try await OriginalGuard.verify(originalRoot: original, manifest: manifest)
        #expect(after.ok && after.checked == 2 && after.skippedUnhashed == 0)
    }
}
