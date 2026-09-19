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
            if !ctx.glob("*.swf", limit: 1).isEmpty {
                r.claimFamily(.flash, 0.8)
                r.add(
                    id,
                    .present(path: ctx.glob("*.swf", limit: 1)[0].realRel),
                    0.8,
                    .fileName,
                    "Flash movie; runs through Ruffle in WebKit"
                )
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
        } else if !ctx.glob("*.pck", limit: 1).isEmpty, !ctx.glob("*.wasm", limit: 1).isEmpty {
            sub = Sub(name: "godotWeb", family: .godotWeb, confidence: 0.95); hints["godotAudioStream"] = "true"
            if !ctx.glob("*.worker.js", limit: 1).isEmpty {
                hints["coopCoep"] = "true"
            }
        } else if ctx.exists("c3runtime.js") || ctx.exists("c2runtime.js") || !ctx.glob("scripts/c3runtime.js", limit: 1).isEmpty {
            sub = (
                "construct",
                .html5,
                0.9
            )
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
        } else if ctx.exists("js/rpg_core.js") || ctx.exists("www/js/rpg_core.js") || ctx.exists("js/rmmz_core.js") || ctx
            .exists("www/js/rmmz_core.js") {
            return r
        } // MV/MZ detector owns it
        let name = sub?.name ?? "generic", family = sub?.family ?? .html5, confidence = sub?.confidence ?? 0.6
        r.claimFamily(family, confidence)
        if let sub {
            r.partial.profileHints["webSubFamily"] = sub.0
        }
        r.add(
            id,
            .present(path: entry),
            confidence,
            sub == nil ? .fileName : .fileContent,
            sub == nil ? "Web page \(entry) with no known engine signature" : "\(name) web build, entry \(entry)"
        )
        r.partial.entryPoint = entry
        for (k, v) in hints {
            r.partial.profileHints[k] = v
        }
        if facts.indexHTMLCandidates.count > 1 {
            r.partial.warnings.append(.multipleEntryPoints(facts.indexHTMLCandidates))
        }
        r.partial.saveFamily = .webLocalStorage
        r.partial.exportPlatform = .web
        r.partial.runtimeCandidates = [RuntimeCandidate(runtime: .web, confidence: confidence, reason: "\(name) runs in WebKit")]
        return r
    }
}
