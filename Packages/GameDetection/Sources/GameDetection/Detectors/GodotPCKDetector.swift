import Foundation
import GameCore
import GameImport

/// Godot PCK header and directory: exact version, pack format, flags, GDExtension and C# markers.
public struct GodotPCKDetector: Detector {
    public let id = DetectorID.godotPCK
    public let version = 1
    public init() {}

    public func probe(_ ctx: ScanContext, facts: StructureFacts) throws -> DetectorReport {
        var r = DetectorReport()
        // A .pck next to index.html and a .wasm is a web export: the web detector owns it.
        if !facts.indexHTMLCandidates.isEmpty, !ctx.glob("*.wasm", limit: 1).isEmpty {
            return r
        }
        struct Source { let url: URL, offset: Int64, name: String }
        var source: Source?
        if let e = ctx.glob("*.pck", limit: 1).first, let url = ctx.url(e.realRel) {
            source = Source(url: url, offset: 0, name: e.realRel)
        } else if case let .godotPCK(offset, _)? = ctx.pePayload?.kind, let exe = facts.exeNames.first, let url = ctx.url(exe) {
            source = (
                url,
                offset,
                exe
            )
        }
        guard let source else { return r }
        let (url, offset, name) = (source.url, source.offset, source.name)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        guard let head = try handle.read(upToCount: 128), head.count >= 20, head.prefix(4).elementsEqual("GDPC".utf8) else {
            if offset == 0 {
                r.add(id, .absent(path: name), 0.3, .fileMagic, "\(name) is not a Godot package")
            }
            return r
        }
        func u32(_ o: Int) -> UInt32 { head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }.littleEndian }
        let format = u32(4), major = u32(8), minor = u32(12), patch = u32(16)
        let v = EngineVersion(major: Int(major), minor: Int(minor), patch: Int(patch))
        r.claimFamily(.godot, 0.98)
        r.add(id, .magic(path: name, bytes: "GDPC v\(format)"), 0.98, .fileMagic, "Godot package format \(format), engine \(v.raw)")
        r.partial.version = v
        if format == 1 || major < 4 {
            r.unsupported = "Godot \(v.raw) exports are not supported; a web export of the same game is"
            return r
        }
        r.partial.generation = .godot4x
        var flags: UInt32 = 0
        if format >= 2, head.count >= 28 {
            flags = u32(20)
        }
        if flags & 1 != 0 {
            r.partial.blockers.append(.encryptedPCK); r.add(
                id,
                .text(path: name, excerpt: "PACK_DIR_ENCRYPTED"),
                0.95,
                .fileMagic,
                "The package directory is encrypted"
            )
        }
        let gdext = ctx.glob("*.gdextension", limit: 16) + ctx.glob("*/*.gdextension", limit: 16)
        if !gdext.isEmpty {
            let names = gdext.map(\.realRel)
            r.partial.blockers.append(.gdextension(names))
            r.add(
                id,
                .count(path: "gdextension", n: names.count),
                0.9,
                .fileName,
                "Native GDExtension libraries: \(names.joined(separator: ", "))"
            )
        }
        if !ctx.glob("data_*_windows_x86_64", limit: 1).isEmpty || !ctx.glob("*/*.dll", limit: 1).filter({ $0.key.contains("godotsharp") })
            .isEmpty {
            r.partial.blockers.append(.csharpExport)
        }
        let bucket: GodotBucket? = minor <= 4 ? .v44 : minor <= 7 ? .v47 : nil
        if let bucket {
            r.partial.runtimeCandidates = [RuntimeCandidate(
                runtime: .godot(bucket: bucket),
                confidence: 0.9,
                reason: "Godot \(major).\(minor) maps to the \(bucket.rawValue) engine bucket"
            )]
        } else {
            r.partial.warnings.append(.unknownVersion(v.raw))
            r.partial.runtimeCandidates = [RuntimeCandidate(
                runtime: .godot(bucket: .v47),
                confidence: 0.5,
                reason: "newer than any bundled Godot; 4.7 is the closest"
            )]
        }
        r.partial.saveFamily = .godotUserDir
        r.partial.exportPlatform = offset > 0 || !facts.exeNames.isEmpty ? .windows : .unknown
        r.partial.entryPoint = name
        return r
    }
}
