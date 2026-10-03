import Foundation
import GameCore

/// Web builds: known engines get a sub-family and profile hints; anything with an index.html is generic HTML5.
public struct WebEngineDetector: Detector {
    public let id = DetectorID.html5Web
    public let version = 1
    public init() {}

    public func probe(_ ctx: ScanContext, facts: StructureFacts) throws -> DetectorReport {
        var r = DetectorReport()
        guard let entry = facts.indexHTMLCandidates.first else {
            if let swf = ctx.glob("*.swf", limit: 1).first {
                r.claimFamily(.flash, 0.8)
                r.add(id, .present(path: swf.realRel), 0.8, .fileName, "Flash movie; runs through Ruffle in WebKit")
                r.partial.runtimeCandidates = [RuntimeCandidate(runtime: .web, confidence: 0.7, reason: "Ruffle inside WebKit")]
            }
            return r
        }
        let index = ctx.text(entry, max: 2 << 20) ?? ""
        struct Sub { let name: String, family: EngineFamily, confidence: Double }
        var sub: Sub?
        var hints: [String: String] = [:]
        if !ctx.glob("build/*.loader.js", limit: 1).isEmpty || index.contains("createUnityInstance(") {
            sub = Sub(name: "unityWeb", family: .unityWeb, confidence: 0.95); hints["forceWebGL2"] = "true"
            if !ctx.glob("build/*.br", limit: 1).isEmpty {
                hints["compression"] = "brotli"
            } else if !ctx.glob("build/*.gz", limit: 1).isEmpty {
                hints["compression"] = "gzip"
            }
            if !ctx.glob("build/*.mem", limit: 1).isEmpty || index.contains("USE_THREADS") {
                hints["coopCoep"] = "true"
            }
            if !ctx.glob("*unityloader.js", limit: 1).isEmpty {
                hints["legacyUnityLoader"] = "true"
            }
        } else if facts.markers.contains(.pck), !ctx.glob("*.wasm", limit: 1).isEmpty {
            sub = Sub(name: "godotWeb", family: .godotWeb, confidence: 0.95); hints["godotAudioStream"] = "true"
            if !ctx.glob("*.worker.js", limit: 1).isEmpty {
                hints["coopCoep"] = "true"
            }
        } else if ctx.exists("c3runtime.js") || ctx.exists("c2runtime.js") || !ctx.glob("scripts/c3runtime.js", limit: 1).isEmpty {
            sub = Sub(name: "construct", family: .html5, confidence: 0.9)
        } else if ctx.entry("tyrano")?.isDir == true || !ctx.glob("data/scenario/*.ks", limit: 1).isEmpty {
            sub = Sub(name: "tyrano", family: .html5, confidence: 0.92)
        } else if index.contains("<tw-storydata") {
            sub = Sub(name: "twine", family: .html5, confidence: 0.92)
        } else if ctx.exists("dmloader.js") {
            sub = Sub(name: "defold", family: .html5, confidence: 0.9)
        } else if ctx.exists("love.wasm") || !ctx.glob("*.love", limit: 1)
            .isEmpty {
            sub = Sub(name: "lovejs", family: .html5, confidence: 0.85); hints["coopCoep"] = "true"
        } else if !ctx.glob("html5game/*.js", limit: 1).isEmpty {
            sub = Sub(name: "gamemakerHTML5", family: .html5, confidence: 0.9)
        } else if ctx.exists("renpy.wasm") {
            sub = Sub(name: "renpyWeb", family: .html5, confidence: 0.9); hints["coopCoep"] = "true"
        } else if facts.markers.contains(.rpgCoreJS) || facts.markers.contains(.rmmzCoreJS) {
            return r // MV/MZ detector owns it
        }
        let name = sub?.name ?? "generic", family = sub?.family ?? .html5, confidence = sub?.confidence ?? 0.6
        r.claimFamily(family, confidence)
        if let sub {
            r.partial.profileHints["webSubFamily"] = sub.name
        }
        r.add(
            id,
            .present(path: entry),
            confidence,
            sub == nil ? .fileName : .fileContent,
            sub == nil ? "Web page \(entry) with no known engine signature" : "\(name) web build, entry \(entry)"
        )
        r.partial.entryPoint = entry
        // The page's own name (`<title>2048</title>`) instead of the folder's; Tyrano's Config.tjs title wins below.
        if let m = index.firstMatch(of: /<title[^>]*>\s*([^<]{1,120}?)\s*<\/title>/.ignoresCase()) {
            r.partial.title = String(m.1)
        }
        for (k, v) in hints {
            r.partial.profileHints[k] = v
        }
        if facts.indexHTMLCandidates.count > 1 {
            r.partial.warnings.append(.multipleEntryPoints(facts.indexHTMLCandidates))
        }
        r.partial.saveFamily = .webLocalStorage
        r.partial.exportPlatform = .web
        r.partial.runtimeCandidates = [RuntimeCandidate(runtime: .web, confidence: confidence, reason: "\(name) runs in WebKit")]
        if sub?.name == "tyrano" {
            tyrano(ctx, &r)
        }
        return r
    }

    /// TyranoScript and TyranoBuilder: engine version from kag.js, title and screen shape from Config.tjs, and game
    /// plugins that reach for Node or Electron, named the way MV/MZ plugins are.
    func tyrano(_ ctx: ScanContext, _ r: inout DetectorReport) {
        let kag = "tyrano/plugins/kag/kag.js"
        // Latin-1 never fails, even on a UTF-8 character cut at the 4 KiB edge; the marker itself is ASCII.
        if let head = ctx.header(kag, bytes: 4 << 10), let text = String(bytes: head, encoding: .isoLatin1),
           let m = text.firstMatch(of: /version\s*:\s*(\d{3,4})\b/), let n = Int(m.1) {
            let v = EngineVersion(major: n / 100, minor: n % 100, raw: String(format: "%d.%02d", n / 100, n % 100))
            r.partial.version = v
            r.add(id, .version(path: kag, value: v.raw), 0.9, .fileContent, "TyranoScript engine \(v.raw)")
        }
        let config = Self.tjsConfig(ctx.text("data/system/Config.tjs", max: 1 << 20) ?? "")
        if let title = config["System.title"], !title.isEmpty {
            r.partial.title = title
        }
        if let w = config["scWidth"].flatMap(Int.init), let h = config["scHeight"].flatMap(Int.init), w != h {
            r.partial.profileHints["orientation"] = w > h ? "landscape" : "portrait"
        }
        // ponytail: `[iscript]` blocks inside .ks files are not scanned; add them if a real game hides Node calls there.
        for plugin in ctx.glob("data/others/*.js", limit: 300) {
            guard let text = ctx.text(plugin.realRel, max: 4 << 20) else { continue }
            let hits = (MVMZPluginScanner.apis + ["studio_api"]).filter(text.contains)
            guard !hits.isEmpty else { continue }
            r.partial.warnings.append(.nodePlugin(file: plugin.realRel, apis: hits))
            r.add(
                id,
                .text(path: plugin.realRel, excerpt: hits.joined(separator: " ")),
                0.8,
                .fileContent,
                "Plugin \(plugin.realRel) uses \(hits.joined(separator: ", "))"
            )
        }
    }

    /// The `;key = value;` lines of a Tyrano Config.tjs, quotes and trailing `//` comments removed.
    static func tjsConfig(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let m = line.firstMatch(of: /^\s*;\s*([\w.]+)\s*=\s*(.*?)\s*;?\s*(\/\/.*)?$/) else { continue }
            out[String(m.1)] = String(m.2).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return out
    }
}
