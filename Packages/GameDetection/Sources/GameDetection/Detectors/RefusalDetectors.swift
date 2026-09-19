import Foundation
import GameCore
import GameImport

/// Native engines OmniPlay cannot run. Each names the engine, the version where it can be read, and what to do instead.
public struct RefusalDetectors: Detector {
    public let id = DetectorID.refusals
    public let version = 1
    public init() {}

    public func probe(_ ctx: ScanContext, facts: StructureFacts) throws -> DetectorReport {
        var r = DetectorReport()
        if let unity = unity(ctx, facts) {
            apply(&r, unity.0, unity.1, refused: true)
        } else if facts.markers.contains(.engineDir), !ctx.glob("*/content/paks/*.pak", limit: 1).isEmpty || !ctx.glob(
            "*/content/paks/*.utoc",
            limit: 1
        ).isEmpty || !ctx.glob("*-win64-shipping.exe", limit: 1).isEmpty {
            apply(
                &r,
                RefusalReason(
                    engine: .unreal,
                    humanMessage: "Unreal Engine games are native Windows programs and cannot run on iPhone.",
                    technicalDetail: "Engine/ with Content/Paks",
                    alternatives: []
                ),
                0.95,
                refused: true
            )
        } else if facts.markers.contains(.dataWin), let e = ctx.glob("data.win", limit: 1).first ?? ctx.glob("game.unx", limit: 1).first,
                  ctx.header(
                      e.realRel,
                      bytes: 4
                  )?.elementsEqual("FORM".utf8) == true {
            apply(
                &r,
                RefusalReason(
                    engine: .gameMaker,
                    humanMessage: "This GameMaker game is a native build. Its HTML5 export would run.",
                    technicalDetail: "\(e.realRel) with FORM chunk",
                    alternatives: ["GameMaker HTML5 export"]
                ),
                0.95,
                refused: true
            )
        } else if !ctx.glob("*.ccn", limit: 1).isEmpty {
            apply(
                &r,
                RefusalReason(
                    engine: .clickteam,
                    humanMessage: "Clickteam Fusion games are native Windows programs.",
                    technicalDetail: ".ccn present"
                ),
                0.9,
                refused: true
            )
        } else if facts.markers.contains(.wolf) || ctx.exists("Data/BasicData/Game.dat") {
            r.claimFamily(.wolfRPG, 0.9)
            r.unsupported = "Wolf RPG Editor games are not supported yet (tracked as post-MVP research)"
            r.add(id, .present(path: "Data/*.wolf"), 0.9, .fileName, "Wolf RPG Editor data files")
        } else if let e = ctx.glob("*.xp3", limit: 1).first, ctx.header(e.realRel, bytes: 3)?.elementsEqual("XP3".utf8) == true {
            r.claimFamily(.kirikiri, 0.9)
            r.unsupported = "KiriKiri (XP3) games are not supported yet"
            r.add(id, .magic(path: e.realRel, bytes: "XP3"), 0.9, .fileMagic, "KiriKiri XP3 archive")
        } else if !ctx.glob("*.ypf", limit: 1).isEmpty {
            apply(
                &r,
                RefusalReason(engine: .yuris, humanMessage: "YU-RIS games are native Windows programs.", technicalDetail: ".ypf archives"),
                0.9,
                refused: true
            )
        } else if !ctx.glob("*.pfs", limit: 1).isEmpty, ctx.glob("*.pck", limit: 1).isEmpty {
            apply(
                &r,
                RefusalReason(
                    engine: .artemis,
                    humanMessage: "Artemis engine games are native Windows programs.",
                    technicalDetail: ".pfs archives"
                ),
                0.85,
                refused: true
            )
        } else if ctx.exists("Scene.pck"), ctx.exists("Gameexe.dat") {
            apply(
                &r,
                RefusalReason(
                    engine: .siglus,
                    humanMessage: "SiglusEngine games are native Windows programs.",
                    technicalDetail: "Scene.pck + Gameexe.dat"
                ),
                0.9,
                refused: true
            )
        }
        return r
    }

    private func apply(_ r: inout DetectorReport, _ reason: RefusalReason, _ confidence: Double, refused: Bool) {
        r.claimFamily(reason.engine, confidence)
        r.refusal = reason
        r.add(id, .text(path: "", excerpt: reason.technicalDetail), confidence, .directoryStructure, reason.humanMessage)
    }

    /// Unity native: player library plus data folder; version from globalgamemanagers; backend from IL2CPP/Mono files.
    private func unity(_ ctx: ScanContext, _ facts: StructureFacts) -> (RefusalReason, Double)? {
        guard facts.markers.contains(.unityPlayer) || !ctx.glob("*_data/globalgamemanagers", limit: 1).isEmpty || ctx
            .exists("data.unity3d") else { return nil }
        var version = "unknown version"
        if let ggm = ctx.glob("*_data/globalgamemanagers", limit: 1).first, let h = ctx.header(ggm.realRel, bytes: 64), h.count >= 0x40 {
            let headerVersion = h.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) }.bigEndian
            let at = headerVersion >= 22 ? 0x30 : 0x14
            let raw = h[h.startIndex + at ..< h.endIndex].prefix { $0 != 0 }
            if let s = String(bytes: raw, encoding: .ascii), s.firstMatch(of: /^\d+\.\d+\.\d+[a-z]\d+/) != nil {
                version = s
            } else if let m = (String(bytes: h, encoding: .isoLatin1) ?? "").firstMatch(of: /\d{4}\.\d+\.\d+[a-z]\d+/) {
                version = String(m.0)
            }
        }
        let backend = facts.markers.contains(.gameAssembly) || !ctx.glob("*/il2cpp_data/metadata/global-metadata.dat", limit: 1).isEmpty ? "IL2CPP"
            : !ctx.glob("*_data/managed/assembly-csharp.dll", limit: 1).isEmpty ? "Mono" : "unknown backend"
        var platform = "Windows"
        var arch = ""
        if let exe = facts.exeNames.first, let url = ctx.url(exe), let pe = try? PEOverlayScanner.scan(url) {
            arch = pe.machine == .x64 ? " x64" : pe.machine == .x86 ? " x86" : ""
        } else if !ctx.glob("lib/*/libunity.so", limit: 1).isEmpty {
            platform = "Android"
        }
        let detail = "Unity \(version) \(backend) \(platform)\(arch)"
        return (
            RefusalReason(
                engine: .unityNative,
                humanMessage: "\(detail) is a native build and cannot run on iPhone. A Unity WebGL export of the same game would.",
                technicalDetail: detail,
                alternatives: ["Unity WebGL export"]
            ),
            0.97
        )
    }
}
