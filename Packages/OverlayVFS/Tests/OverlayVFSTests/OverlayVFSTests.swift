import Foundation
import GameCore
import OverlayVFS
import Testing
import TestSupport

/// Every asset a game reads comes through the resolver, so a wrong layer order silently serves the
/// original over a mod, and a path that escapes the policy reads outside the game folder entirely.
@Suite("Overlay resolver")
struct OverlayResolverTests {
    @Test("Resolution order is Overrides → Generated → Original → RTP, and the path policy rejects escapes")
    func resolution() async throws {
        let root = try TemporaryGameRoot(name: "ovl")
        defer { root.remove() }
        let paths = AppPaths(
            root: root.url.appending(path: "Support"),
            cachesRoot: root.url.appending(path: "Caches"),
            exportsRoot: root.url.appending(path: "Export")
        )
        let game = GameDescriptor(title: "T", engine: .rpgMakerXP, identityHash: "h")
        try paths.ensureLayout()
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

        #expect(PathPolicy.validateLogical("Graphics/Title.png") == "graphics/title.png")
        #expect(PathPolicy.validateLogical("a\\b//c") == "a/b/c")
        for bad in ["../x", "a/../b", "/abs", "\\abs", "a/./b", "a\u{0}b", "a\nb", "", "..", "."] {
            #expect(PathPolicy.validateLogical(bad) == nil, "\(bad.debugDescription) should be rejected")
        }
    }
}
