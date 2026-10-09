import Foundation
import GameCore

/// Cheap facts every detector shares, computed once from index lookups and bounded listings.
public struct StructureFacts: Sendable, Hashable {
    public enum Marker: String, Sendable, CaseIterable, Hashable {
        case gameIni, rgssArchive, renpyDir, gameDir, packageJSON, rpgCoreJS, rmmzCoreJS, systemJSON, rpgRTLdb, pck
        case unityPlayer, gameAssembly, unityData, engineDir, dataWin, mainLua, nscriptDat, swf, acsetupCfg, xp3
    }

    public var hasWWW = false
    public var indexHTMLCandidates: [String] = []
    public var exeNames: [String] = []
    public var markers: Set<Marker> = []

    public static func inspect(_ ctx: ScanContext) -> StructureFacts {
        var f = StructureFacts()
        f.hasWWW = ctx.entry("www")?.isDir == true
        for e in ctx.children("", limit: 512) where !e.isDir && e.key.hasSuffix(".exe") {
            f.exeNames.append(e.realRel)
        }
        for candidate in ["index.html", "www/index.html", "index.htm"]
            where ctx.exists(candidate) {
            f.indexHTMLCandidates.append(candidate)
        }
        if f.indexHTMLCandidates.isEmpty {
            // GLOB's `*` crosses folders. An index page at any depth (an Electron app keeps its own in a folder such as
            // production/) comes before other pages, shallow before deep; library pages under node_modules never count.
            let pages = ctx.glob("*.html", limit: 512).map(\.realRel).filter { !$0.lowercased().contains("node_modules/") }
            let rank = { (page: String) in (page.lowercased().hasSuffix("index.html") ? 0 : 1, page.count(where: { $0 == "/" })) }
            f.indexHTMLCandidates = Array(pages.sorted { rank($0) < rank($1) }.prefix(8))
        }
        let checks: [(Marker, [String])] = [
            (.gameIni, ["game.ini"]), (.renpyDir, ["renpy"]), (.gameDir, ["game"]), (.packageJSON, ["package.json", "www/package.json"]),
            (.rpgCoreJS, ["js/rpg_core.js", "www/js/rpg_core.js"]), (.rmmzCoreJS, ["js/rmmz_core.js", "www/js/rmmz_core.js"]),
            (.systemJSON, ["data/system.json", "www/data/system.json"]), (.rpgRTLdb, ["rpg_rt.ldb"]),
            (.unityPlayer, ["unityplayer.dll", "unityplayer.so", "unityplayer.dylib"]), (.gameAssembly, ["gameassembly.dll"]),
            (.engineDir, ["engine"]), (.dataWin, ["data.win", "game.unx", "game.ios"]), (.mainLua, ["main.lua"]), (
                .nscriptDat,
                ["nscript.dat"]
            ),
            (.acsetupCfg, ["acsetup.cfg"]),
        ]
        for (marker, paths) in checks where paths.contains(where: ctx.exists) {
            f.markers.insert(marker)
        }
        if !ctx.glob("*.rgssad", limit: 1).isEmpty || !ctx.glob("*.rgss2a", limit: 1).isEmpty || !ctx.glob("*.rgss3a", limit: 1)
            .isEmpty {
            f.markers.insert(.rgssArchive)
        }
        if !ctx.glob("*.pck", limit: 1).isEmpty {
            f.markers.insert(.pck)
        }
        if !ctx.glob("*_data", limit: 1).filter(\.isDir).isEmpty {
            f.markers.insert(.unityData)
        }
        if !ctx.glob("*.swf", limit: 1).isEmpty {
            f.markers.insert(.swf)
        }
        if !ctx.glob("*.xp3", limit: 1).isEmpty {
            f.markers.insert(.xp3)
        }
        return f
    }
}
