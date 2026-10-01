import Foundation
import GameCore

/// Cheap facts every detector shares, computed once from index lookups and bounded listings.
public struct StructureFacts: Sendable, Hashable {
    public enum Marker: String, Sendable, CaseIterable, Hashable {
        case gameIni, rgssArchive, renpyDir, gameDir, packageJSON, rpgCoreJS, rmmzCoreJS, systemJSON, rpgRTLdb, pck
        case unityPlayer, gameAssembly, unityData, engineDir, dataWin, mainLua, nscriptDat, swf, acsetupCfg, xp3
    }

    public var topLevelNames: [String] = []
    public var hasWWW = false
    public var indexHTMLCandidates: [String] = []
    public var exeNames: [String] = []
    public var dllNames: [String] = []
    public var markers: Set<Marker> = []
    public var entryCount = 0

    public static func inspect(_ ctx: ScanContext) -> StructureFacts {
        var f = StructureFacts()
        let top = ctx.children("", limit: 512)
        f.topLevelNames = top.map(\.realRel)
        f.entryCount = ctx.count()
        f.hasWWW = ctx.entry("www")?.isDir == true
        for e in top where !e.isDir {
            let lower = e.key
            if lower.hasSuffix(".exe") {
                f.exeNames.append(e.realRel)
            }
            if lower.hasSuffix(".dll"), f.dllNames.count < 64 {
                f.dllNames.append(e.realRel)
            }
        }
        for candidate in ["index.html", "www/index.html", "index.htm"]
            where ctx.exists(candidate) {
            f.indexHTMLCandidates.append(candidate)
        }
        if f.indexHTMLCandidates.isEmpty {
            for e in ctx.glob("*.html", limit: 8) + ctx.glob("*/*.html", limit: 8)
                where f.indexHTMLCandidates.count < 8 {
                f.indexHTMLCandidates.append(e.realRel)
            }
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
