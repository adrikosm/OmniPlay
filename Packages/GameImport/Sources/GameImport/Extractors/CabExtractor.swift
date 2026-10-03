import CMspack
import Foundation

/// Microsoft cabinets through libmspack: plain `.cab` files and self-extracting installers with cabinets inside
/// (libmspack finds them itself). libarchive's LZX decoder fails on large real installers; libmspack does not.
/// libmspack only decodes: OmniPlay validates names and owns every output write, as with RAR.
public struct CabExtractor: Sendable {
    public let limits: SafetyLimits
    public init(limits: SafetyLimits = .default) { self.limits = limits }

    public func preflight(_ url: URL) throws -> ArchivePreflight {
        let cab = try open(url)
        defer { op_cab_close(cab) }
        var result = ArchivePreflight()
        var totals = RunningTotals()
        let validator = EntryValidator(limits: limits)
        for index in 0 ..< Int(op_cab_count(cab)) {
            try Task.checkCancellation()
            let header = try header(cab, index)
            if case let .reject(error) = validator.validate(header, running: &totals) {
                throw error
            }
            result.entries += 1
            result.declaredBytes = totals.declaredBytes
        }
        return result
    }

    public func extract(_ url: URL, to destination: URL, progress: (@Sendable (Int64, String) -> Void)? = nil) throws -> RunningTotals {
        let cab = try open(url)
        defer { op_cab_close(cab) }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let validator = EntryValidator(limits: limits)
        let sink = try StreamingSink(
            label: "cabinet",
            validator: validator,
            sourceBytes: Int64(url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0),
            progress: progress
        )
        for index in 0 ..< Int(op_cab_count(cab)) {
            try Task.checkCancellation()
            let header = try header(cab, index)
            switch validator.validate(header, running: &sink.totals) {
            case let .reject(error): throw error
            case .skip: continue
            case let .extract(relative):
                let target = try StreamingSink.target(relative, in: destination)
                if sink.skipsDuplicate(target, declaredSize: header.declaredSize) {
                    continue
                }
                try sink.stream(to: target, path: relative, declaredSize: header.declaredSize) { callback, context in
                    let code = op_cab_extract(cab, Int32(index), callback, context)
                    guard code == 0 else { throw ExtractionError.entry(path: relative, message: "cabinet error \(code)") }
                }
            }
        }
        return sink.totals
    }

    private func open(_ url: URL) throws -> OpaquePointer {
        try Task.checkCancellation()
        var code: Int32 = 0
        guard let cab = op_cab_open(url.path(percentEncoded: false), &code) else {
            throw ExtractionError.open("no readable cabinet (libmspack error \(code))")
        }
        return cab
    }

    private func header(_ cab: OpaquePointer, _ index: Int) throws -> ArchiveEntryHeader {
        var entry = OPCabEntry()
        guard op_cab_entry(cab, Int32(index), &entry) == 0, let raw = entry.path else {
            throw ExtractionError.entry(path: "(header)", message: "cabinet entry \(index) unreadable")
        }
        // Flagged UTF-8, else the bytes as stored: Japanese installers write Shift-JIS whatever the format says.
        let bytes = Data(bytes: raw, count: strlen(raw))
        let path = entry.utf8 != 0 ? String(data: bytes, encoding: .utf8)
            : String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .shiftJIS) ?? String(
                data: bytes,
                encoding: .isoLatin1
            )
        guard let path else {
            throw ExtractionError.entry(path: "(header)", message: "cabinet entry \(index) has an invalid filename encoding")
        }
        return ArchiveEntryHeader(path: path, kind: .file, declaredSize: Int64(entry.size))
    }
}
