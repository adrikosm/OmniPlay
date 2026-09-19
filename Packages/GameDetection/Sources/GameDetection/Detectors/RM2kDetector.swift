import Foundation
import GameCore

/// RPG Maker 2000 / 2003 (LCF databases). The 2000-vs-2003 split is inferred until liblcf confirms it.
public struct RM2kDetector: Detector {
    public let id = DetectorID.rm2k3
    public let version = 1
    public init() {}

    public func probe(_ ctx: ScanContext, facts: StructureFacts) throws -> DetectorReport {
        var r = DetectorReport()
        guard ctx.exists("RPG_RT.ldb") || ctx.exists("RPG_RT.lmt") else { return r }
        guard let h = ctx.header("RPG_RT.ldb", bytes: 32), h.count > 12, h[h.startIndex] == 0x0B,
              h.dropFirst(1).prefix(11).elementsEqual("LcfDataBase".utf8) else {
            r.unsupported = "incomplete RPG Maker 2000/2003 distribution: RPG_RT.ldb missing or invalid"
            r.claimFamily(.rpgMaker2000, 0.6)
            r.add(id, .absent(path: "RPG_RT.ldb"), 0.6, .fileMagic, "RPG_RT.ldb is missing or not an LCF database")
            return r
        }
        r.add(id, .magic(path: "RPG_RT.ldb", bytes: "LcfDataBase"), 0.95, .fileMagic, "RPG_RT.ldb is an LCF database")
        // [INFERRED] 2003 databases carry chunk 0x1D (battle commands) and later chunks; a stub without chunks reads as 2000.
        let tail = h.dropFirst(12)
        let is2003 = tail.contains(0x1D) || ctx.exists("RPG_RT.exe") && ctx.glob("*.xyz", limit: 1).isEmpty && ctx.glob(
            "charset/*.png",
            limit: 1
        ).isEmpty == false
        let family: EngineFamily = is2003 ? .rpgMaker2003 : .rpgMaker2000
        r.claimFamily(family, 0.9)
        r.add(
            id,
            .text(path: "RPG_RT.ldb", excerpt: is2003 ? "2003 chunks" : "no 2003 chunks"),
            0.6,
            .fileContent,
            "[INFERRED] \(family.rawValue) from database chunks"
        )
        var fullPackage = false
        if let ini = ctx.text("RPG_RT.ini", max: 64 << 10) {
            fullPackage = ini.contains("FullPackageFlag=1")
            if let m = ini
                .firstMatch(of: /GameTitle=(.+)/) {
                r.partial.title = String(m.1).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if !fullPackage {
            r.partial.warnings.append(.rtpRequired(is2003 ? "RPG Maker 2003 RTP" : "RPG Maker 2000 RTP"))
        }
        r.partial.saveFamily = .easyrpgLSD
        r.partial.exportPlatform = .windows
        r.partial.entryPoint = "RPG_RT.ldb"
        r.partial.runtimeCandidates = [RuntimeCandidate(runtime: .easyrpg, confidence: 0.9, reason: "EasyRPG Player runs 2000/2003 games")]
        return r
    }
}
