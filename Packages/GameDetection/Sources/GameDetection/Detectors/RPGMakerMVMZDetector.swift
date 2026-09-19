import Foundation
import GameCore

/// RPG Maker MV / MZ: the core script name decides, its version string dates it, System.json says whether
/// assets are encrypted and what the game is called.
public struct RPGMakerMVMZDetector: Detector {
    public let id = DetectorID.rpgMakerMVMZ
    public let version = 1
    public init() {}

    public func probe(_ ctx: ScanContext, facts: StructureFacts) throws -> DetectorReport {
        var r = DetectorReport()
        let prefix = facts.hasWWW && !ctx.exists("js/rpg_core.js") && !ctx.exists("js/rmmz_core.js") ? "www/" : ""
        let cores: [(String, EngineFamily, EngineGeneration)] = [
            ("js/rpg_core.js", .rpgMakerMV, .mv),
            ("js/rmmz_core.js", .rpgMakerMZ, .mz),
        ]
        guard let (core, family, generation) = cores.first(where: { ctx.exists(prefix + $0.0) }) else { return r }
        let corePath = prefix + core
        r.claimFamily(family, 0.98)
        r.partial.generation = generation
        r.add(id, .present(path: corePath), 0.98, .fileName, "\(corePath) is the \(family == .rpgMakerMV ? "MV" : "MZ") core script")
        if let head = ctx.header(corePath, bytes: 64 << 10), let text = String(data: head, encoding: .utf8) ?? String(
            data: head,
            encoding: .isoLatin1
        ),
            let m = text.firstMatch(of: /RPGMAKER_VERSION\s*=\s*"([^"]+)"/) {
            let v = String(m.1)
            r.partial.version = EngineVersion(parsing: v)
            r.add(id, .version(path: corePath, value: v), 0.95, .fileContent, "Core script version \(v)")
        } else {
            r.partial.warnings.append(.unknownVersion("no RPGMAKER_VERSION in \(corePath)"))
        }
        if let data = ctx.smallFile(prefix + "data/System.json", max: 4 << 20),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let title = json["gameTitle"] as? String, !title.isEmpty {
                r.partial.title = title
            }
            let encrypted = json["hasEncryptedImages"] as? Bool == true || json["hasEncryptedAudio"] as? Bool == true ||
                json["encryptionKey"] != nil
            r.partial.profileHints["encryptedAssets"] = encrypted ? "true" : "false"
            r.add(
                id,
                .text(path: prefix + "data/System.json", excerpt: encrypted ? "encryptionKey" : "plain"),
                0.9,
                .fileContent,
                encrypted ? "Assets are encrypted (System.json carries the key)" : "Assets are not encrypted"
            )
        } else if ctx.exists(prefix + "data/System.json") {
            r.partial.warnings.append(.note("data/System.json could not be parsed"))
        }
        let entry = ["index.html", "www/index.html"].first(where: ctx.exists)
        r.partial.entryPoint = entry
        if let entry {
            r.add(id, .present(path: entry), 0.9, .fileName, "Entry page \(entry)")
        }
        if let pkg = ctx.smallFile("package.json", max: 1 << 20), let json = try? JSONSerialization.jsonObject(with: pkg) as? [String: Any],
           let name = json["name"] as? String {
            r.add(id, .text(path: "package.json", excerpt: name), 0.6, .fileContent, "NW.js package \"\(name)\"")
        }
        if ctx.exists(prefix + "js/libs/vorbisdecoder.js") {
            r.partial.profileHints["vorbisDecoder"] = "true"
        }
        r.partial.profileHints["webProfile"] = generation == .mv ? "mv" : "mz"
        r.partial.saveFamily = generation == .mv ? .webLocalStorage : .webIndexedDB
        r.partial.exportPlatform = facts.exeNames.isEmpty ? (facts.hasWWW ? .windows : .web) : .windows
        r.partial.runtimeCandidates = [RuntimeCandidate(
            runtime: .web,
            confidence: 0.98,
            reason: "RPG Maker \(generation == .mv ? "MV" : "MZ") runs in WebKit"
        )]
        let movies = ctx.glob(prefix + "movies/*.webm", limit: 64)
        let mp4s = Set(ctx.glob(prefix + "movies/*.mp4", limit: 64).map { $0.key.dropLast(4) })
        r.add(
            id,
            .count(path: prefix + "movies", n: movies.count),
            0.5,
            .directoryStructure,
            "\(movies.count) WebM movies, \(movies.filter { mp4s.contains($0.key.dropLast(5)) }.count) with MP4 siblings"
        )
        return r
    }
}

/// Plugins that reach for Node or NW.js APIs: named per file so the player knows what may break.
public struct MVMZPluginScanner: Detector {
    public let id = DetectorID.mvmzPlugins
    public let version = 1
    static let apis = [
        "require('fs'",
        "require(\"fs\"",
        "require('path'",
        "require(",
        "process.",
        "nw.",
        "child_process",
        "evalNWBin",
        "greenworks",
        "fs.",
        "path.",
    ]
    static let blocking = ["child_process", ".node\""]
    public init() {}

    public func probe(_ ctx: ScanContext, facts: StructureFacts) throws -> DetectorReport {
        var r = DetectorReport()
        let prefix = facts.hasWWW && !ctx.exists("js/plugins.js") ? "www/" : ""
        guard ctx.exists(prefix + "js/rpg_core.js") || ctx.exists(prefix + "js/rmmz_core.js") else { return r }
        var names: [String] = []
        if let list = ctx.text(prefix + "js/plugins.js", max: 4 << 20), let open = list.firstIndex(of: "["),
           let close = list.lastIndex(of: "]"),
           let data = String(list[open ... close]).data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            names = arr.filter { ($0["status"] as? Bool) ?? true }.compactMap { $0["name"] as? String }
        } else {
            names = ctx.glob(prefix + "js/plugins/*.js", limit: 300).map { String($0.realRel.split(separator: "/").last!.dropLast(3)) }
            if !names.isEmpty {
                r.partial.warnings.append(.note("plugins.js unreadable; scanned every plugin file"))
            }
        }
        for name in names.prefix(300) {
            let path = prefix + "js/plugins/\(name).js"
            guard let text = ctx.text(path, max: 4 << 20) else { continue }
            let hits = Self.apis.filter(text.contains)
            guard !hits.isEmpty else { continue }
            r.partial.warnings.append(.nodePlugin(file: path, apis: hits))
            r.add(
                id,
                .text(path: path, excerpt: hits.joined(separator: " ")),
                0.8,
                .fileContent,
                "Plugin \(name) uses \(hits.joined(separator: ", "))"
            )
            if let hard = Self.blocking.first(where: text.contains) {
                r.partial.blockers.append(.nodePlugin(file: path, api: hard))
            }
        }
        return r
    }
}
