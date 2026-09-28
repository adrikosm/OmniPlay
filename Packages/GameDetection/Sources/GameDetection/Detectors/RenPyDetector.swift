import Foundation
import GameCore

/// Ren'Py: `lib/` folder names are an exact Python-generation oracle; vc_version.py / __init__.py give the version.
public struct RenPyDetector: Detector {
    public let id = DetectorID.renpy
    public let version = 1
    public init() {}

    public func probe(_ ctx: ScanContext, facts: StructureFacts) throws -> DetectorReport {
        var r = DetectorReport()
        let hasRenpy = ctx.entry("renpy")?.isDir == true
        let firstScript = ctx.glob("game/*.rpyc", limit: 1).first
        let hasGame = ctx.entry("game")?.isDir == true && (firstScript != nil || !ctx.glob("game/*.rpa", limit: 1).isEmpty || !ctx.glob(
            "game/*.rpy",
            limit: 1
        ).isEmpty)
        guard hasRenpy || hasGame else { return r }
        r.claimFamily(.renpy, hasRenpy && hasGame ? 0.97 : 0.85)
        if hasRenpy {
            r.add(id, .present(path: "renpy"), 0.9, .directoryStructure, "renpy/ engine folder present")
        }
        if let s = firstScript, let h = ctx.header(s.realRel, bytes: 10), h.elementsEqual("RENPY RPC2".utf8) {
            r.add(id, .magic(path: s.realRel, bytes: "RENPY RPC2"), 0.95, .fileMagic, "\(s.realRel) is compiled Ren'Py script")
        }
        if !hasRenpy {
            r.partial.warnings.append(.note("renpy/ folder missing; detected from game/ scripts only"))
        }
        // The game's own name when its options script ships as source (`define config.name = _("The Question")`);
        // compiled-only games keep the folder name.
        if let options = ctx.text("game/options.rpy", max: 256 << 10),
           // Closed by the quote that opened it: "Ren'Py Tutorial Game" keeps its apostrophe.
           let m = options.firstMatch(of: /define\s+config\.name\s*=\s*_?\(?\s*u?(["'])([^\n]+?)\1/) {
            r.partial.title = String(m.2)
        }

        var version: EngineVersion?
        // Ren'Py writes `version = '8.5.3.26051504'` (7.8.x: `u'...'`); `vc_version = 1234` in older releases is not it.
        if let vc = ctx.text("renpy/vc_version.py", max: 64 << 10), let m = vc.firstMatch(of: /\bversion\s*=\s*u?['"]([0-9][^'"]*)['"]/) {
            version = EngineVersion(parsing: String(m.1))
            r.add(id, .version(path: "renpy/vc_version.py", value: String(m.1)), 0.97, .fileContent, "Ren'Py \(m.1)")
        } else if let initFile = ctx.text("renpy/__init__.py", max: 256 << 10) {
            if let m = initFile.firstMatch(of: /version_tuple\s*=\s*\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/) {
                version = EngineVersion(major: Int(m.1)!, minor: Int(m.2)!, patch: Int(m.3)!)
                r.add(id, .version(path: "renpy/__init__.py", value: version!.raw), 0.95, .fileContent, "Ren'Py \(version!.raw)")
            } else if let m = initFile.firstMatch(of: /version\s*=\s*"Ren'Py ([0-9.]+)/) {
                version = EngineVersion(parsing: String(m.1))
                r.add(id, .version(path: "renpy/__init__.py", value: String(m.1)), 0.9, .fileContent, "Ren'Py \(m.1)")
            }
        }
        if version == nil, let sv = ctx.text("game/script_version.txt", max: 4096),
           let m = sv.firstMatch(of: /(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/) {
            version = EngineVersion(major: Int(m.1)!, minor: Int(m.2)!, patch: Int(m.3)!)
            r.add(
                id,
                .version(path: "game/script_version.txt", value: version!.raw),
                0.7,
                .fileContent,
                "Scripts were compiled by Ren'Py \(version!.raw)"
            )
        }

        var generation: EngineGeneration?
        let libs = ctx.children("lib", limit: 64).map { $0.realRel.lowercased() }
        if libs.contains(where: { $0.contains("python3.12") }) {
            generation = .renpyPy312
        } else if libs.contains(where: { $0.contains("python3.9") || $0.contains("py3-") }) {
            generation = .renpyPy39
        } else if libs
            .contains(where: { $0.contains("pythonlib2.7") || $0.contains("py2-") || $0.contains("windows-i686") }) {
            generation = .renpyPy27
        }
        if let g = generation {
            r.add(id, .present(path: "lib"), 0.95, .directoryStructure, "lib/ names a \(Self.pythonName(g)) build")
        }
        if generation == nil, ctx.exists("game/cache/bytecode-312.rpyb") {
            generation = .renpyPy312
        }
        if generation == nil, ctx.exists("game/cache/bytecode-39.rpyb") {
            generation = .renpyPy39
        }
        if generation == nil, let v = version {
            generation = v.major >= 8 ? (v.minor >= 4 ? .renpyPy312 : .renpyPy39) : .renpyPy27
        }
        if let g = generation, let v = version, Self.pythonMismatch(g, v) {
            r.partial.warnings.append(.unknownVersion("lib/ says \(Self.pythonName(g)) but the version is \(v.raw)"))
        }
        if libs.contains(where: { $0.contains("windows") }) {
            r.partial.exportPlatform = .windows
        } else if libs.contains(where: { $0.contains("linux") }) {
            r.partial.exportPlatform = .linux
        } else if libs.contains(where: { $0.contains("mac") || $0.contains("darwin") }) {
            r.partial.exportPlatform = .macos
        }
        if ctx.exists("renpy.wasm") || ctx.exists("renpy.js") {
            r.partial.exportPlatform = .web
        }
        if ctx.entry("game/live2d")?.isDir == true || !ctx.glob("*live2d*", limit: 1)
            .isEmpty {
            r.partial.warnings.append(.live2dRequiresLicensedCore)
        }
        r.partial.version = version
        r.partial.generation = generation
        r.partial.saveFamily = .renpySave
        r.partial.entryPoint = "game"
        return r
    }

    static func pythonName(_ g: EngineGeneration) -> String { g == .renpyPy27 ? "Python 2.7" : g == .renpyPy39 ? "Python 3.9" :
        "Python 3.12"
    }

    static func pythonMismatch(_ g: EngineGeneration, _ v: EngineVersion) -> Bool {
        switch g {
        case .renpyPy27: v.major >= 8
        case .renpyPy39: v.major < 8 || v.minor >= 4
        case .renpyPy312: v.major < 8 || v.minor < 4
        default: false
        }
    }
}
