import Foundation
import GameCore

/// RPG Maker 2000 / 2003 (LCF databases). The database's own `System.ldb_id` says which: 2003 for RPG Maker 2003,
/// absent for 2000, the rule EasyRPG and the original runtimes follow.
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
        let ldbID = ctx.url("RPG_RT.ldb").flatMap(Self.ldbID)
        let family: EngineFamily = ldbID == 2003 ? .rpgMaker2003 : .rpgMaker2000
        r.claimFamily(family, 0.9)
        r.add(
            id,
            .text(path: "RPG_RT.ldb", excerpt: "ldb_id \(ldbID.map(String.init) ?? "absent")"),
            0.9,
            .fileContent,
            "\(family.rawValue): System.ldb_id is \(ldbID.map(String.init) ?? "absent")"
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
            r.partial.warnings.append(.rtpRequired(family == .rpgMaker2003 ? "RPG Maker 2003 RTP" : "RPG Maker 2000 RTP"))
        }
        r.partial.saveFamily = .easyrpgLSD
        r.partial.exportPlatform = .windows
        r.partial.entryPoint = "RPG_RT.ldb"
        r.partial.runtimeCandidates = [RuntimeCandidate(runtime: .easyrpg, confidence: 0.9, reason: "EasyRPG Player runs 2000/2003 games")]
        return r
    }

    /// `System.ldb_id` from an RPG_RT.ldb: the database is chunks of (id, size, data) with LCF's 7-bit variable-length
    /// integers, so the top level is walked by sizes and only the System chunk (0x16) is read. Every length is checked
    /// against the file and the walk is bounded, so a damaged database reads as nil.
    static func ldbID(_ url: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let length = try? handle.seekToEnd() else { return nil }
        var offset: UInt64 = 12 // "\x0bLcfDataBase"
        for _ in 0 ..< 64 { // the format has about 25 top-level chunks
            guard (try? handle.seek(toOffset: offset)) != nil, let head = try? handle.read(upToCount: 10) else { return nil }
            var i = 0
            guard let chunk = lcfInt(head, &i), chunk != 0, let size = lcfInt(head, &i) else { return nil }
            let body = offset + UInt64(i)
            guard body + UInt64(size) <= length else { return nil }
            guard chunk == 0x16 else { offset = body + UInt64(size); continue }
            guard size <= 1 << 20, (try? handle.seek(toOffset: body)) != nil, let system = try? handle.read(upToCount: size),
                  system.count == size else { return nil }
            var j = 0
            while j < system.count, let field = lcfInt(system, &j), field != 0, let fieldSize = lcfInt(system, &j) {
                guard j + fieldSize <= system.count else { return nil }
                if field == 0x0A {
                    var k = 0
                    return lcfInt(system.subdata(in: j ..< j + fieldSize), &k)
                }
                j += fieldSize
            }
            return nil
        }
        return nil
    }

    /// One LCF integer: big-endian 7-bit groups, high bit set on every byte but the last; at most five bytes.
    static func lcfInt(_ data: Data, _ i: inout Int) -> Int? {
        var value = 0
        for _ in 0 ..< 5 {
            guard i < data.count else { return nil }
            let byte = data[data.startIndex + i]
            i += 1
            value = value << 7 | Int(byte & 0x7F)
            if byte & 0x80 == 0 {
                return value
            }
        }
        return nil
    }
}
