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
        } else {
            // A self-contained export: the pack sits at the tail of the .exe, whether the .exe was the import itself or
            // arrived inside a folder or zip (next to a console .exe, which has no pack).
            for exe in facts.exeNames.prefix(4) {
                guard let url = ctx.url(exe) else { continue }
                if case let .godotPCK(offset, _)? = (ctx.pePayload ?? (try? PEOverlayScanner.scan(url)))?.kind {
                    source = Source(url: url, offset: offset, name: exe)
                    break
                }
            }
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
        if major < 3 {
            r.unsupported = "Godot \(v.raw) exports are not supported; a web export of the same game is"
            return r
        }
        r.partial.generation = major == 3 ? .godot3x : .godot4x
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
        let (candidates, warning) = Self.candidates(major: Int(major), minor: Int(minor), raw: v.raw)
        r.partial.runtimeCandidates = candidates
        if let warning {
            r.partial.warnings.append(warning)
        }
        r.partial.saveFamily = .godotUserDir
        r.partial.exportPlatform = offset > 0 || !facts.exeNames.isEmpty ? .windows : .unknown
        r.partial.entryPoint = name
        if flags & 1 == 0, let title = try? Self.projectName(handle: handle, packStart: offset, format: format, flags: flags) {
            r.partial.title = title
        }
        return r
    }

    /// Godot 3 packs (format 1) run on the 3.6 engine: 3.x kept its pack and resource formats across minors. 4.0–4.4
    /// prefer a 4.4 engine and, until one is built, open on 4.7, which reads older 4.x packs and resources; the
    /// resolver takes the first candidate this build has. Newer than 4.7 tries 4.7 with a warning.
    static func candidates(major: Int, minor: Int, raw: String) -> ([RuntimeCandidate], GameWarning?) {
        let bucket: GodotBucket? = major == 3 ? .v36 : minor <= 4 ? .v44 : minor <= 7 ? .v47 : nil
        guard let bucket else {
            return (
                [RuntimeCandidate(
                    runtime: .godot(bucket: .v47),
                    confidence: 0.5,
                    reason: "newer than any bundled Godot; 4.7 is the closest"
                )],
                .unknownVersion(raw)
            )
        }
        var list = [RuntimeCandidate(
            runtime: .godot(bucket: bucket),
            confidence: 0.9,
            reason: "Godot \(major).\(minor) maps to the \(bucket.rawValue) engine bucket"
        )]
        if bucket == .v44 {
            list.append(RuntimeCandidate(
                runtime: .godot(bucket: .v47),
                confidence: 0.75,
                reason: "Godot 4.\(minor) packs also open on the 4.7 engine"
            ))
        }
        return (list, nil)
    }

    /// `application/config/name` from the pack's `project.binary`, the game's own name (the import's file name is
    /// "turbofat-win-v1.1215"). Untrusted bytes: every count, length and offset is bounded, and data counts only when
    /// it starts with the config magic. Pack format 1 addresses files from the file start, 2 from a file base that may
    /// be relative to the pack, 3 adds a directory offset; each plausible origin is tried.
    static func projectName(handle: FileHandle, packStart: Int64, format: UInt32, flags: UInt32) throws -> String? {
        func read(_ at: Int64, _ count: Int) throws -> Data? {
            guard at >= 0, count >= 0 else { return nil }
            try handle.seek(toOffset: UInt64(at))
            let data = try handle.read(upToCount: count) ?? Data()
            return data.count == count ? data : nil
        }
        func u32(_ d: Data, _ o: Int) -> Int { Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }.littleEndian)
        }
        func u64(
            _ d: Data,
            _ o: Int
        ) -> Int64 { Int64(bitPattern: d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self) }.littleEndian)
        }
        guard let head = try read(packStart, 128) else { return nil }
        var fileBase: Int64 = 0, cursor: Int64
        switch format {
        case 1: cursor = packStart + 20 + 64
        case 2: fileBase = u64(head, 24); cursor = packStart + 32 + 64
        default: fileBase = u64(head, 24); cursor = packStart + u64(head, 32)
        }
        guard let countData = try read(cursor, 4) else { return nil }
        let count = u32(countData, 0)
        guard count > 0, count <= 200_000 else { return nil }
        cursor += 4
        for _ in 0 ..< count {
            guard let lenData = try read(cursor, 4) else { return nil }
            let length = u32(lenData, 0)
            guard length > 0, length <= 4096, let pathData = try read(cursor + 4, length) else { return nil }
            cursor += 4 + Int64(length)
            let tail = format == 1 ? 32 : 36 // offset, size, md5 (and flags from format 2)
            guard let entry = try read(cursor, tail) else { return nil }
            cursor += Int64(tail)
            let path = String(bytes: pathData.prefix { $0 != 0 }, encoding: .utf8) ?? ""
            guard path.hasSuffix("project.binary") else { continue }
            let (fileOffset, size) = (u64(entry, 0), u64(entry, 8))
            guard size > 8, size <= 1 << 20 else { return nil }
            for origin in [0, packStart, fileBase, packStart + fileBase] {
                if let config = try read(origin + fileOffset, Int(size)), config.prefix(4).elementsEqual("ECFG".utf8) {
                    return configName(config)
                }
            }
            return nil
        }
        return nil
    }

    /// ProjectSettings' binary form: "ECFG", a count, then each key (length + UTF-8) and its encoded Variant
    /// (length + type + value). Only a String `application/config/name` is read.
    static func configName(_ d: Data) -> String? {
        func u32(_ o: Int) -> Int? {
            guard o >= 0, o + 4 <= d.count else { return nil }
            return Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }.littleEndian)
        }
        guard let count = u32(4), count <= 10000 else { return nil }
        var o = 8
        for _ in 0 ..< count {
            guard let keyLength = u32(o), keyLength <= 1024, o + 4 + keyLength <= d.count else { return nil }
            let key = String(bytes: d[(o + 4) ..< (o + 4 + keyLength)], encoding: .utf8) ?? ""
            o += 4 + keyLength
            guard let valueLength = u32(o), valueLength <= d.count - o - 4 else { return nil }
            if key == "application/config/name", let type = u32(o + 4), type & 0xFFFF == 4, let length = u32(o + 8),
               length > 0, length <= 256, o + 12 + length <= d.count {
                let name = (String(bytes: d[(o + 12) ..< (o + 12 + length)], encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : name
            }
            o += 4 + valueLength
        }
        return nil
    }
}
