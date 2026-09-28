import CMspack
import Darwin
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
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let validator = EntryValidator(limits: limits)
        let sink = try CabSink(
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
                let target = destination.appending(path: relative)
                let rootPath = destination.resolvingSymlinksInPath().pathComponents
                let targetPath = target.resolvingSymlinksInPath().pathComponents
                guard targetPath.count > rootPath.count, targetPath.starts(with: rootPath) else {
                    throw SafetyViolation(rule: .invalidPath, entryPath: relative, detail: "symlink escapes staging")
                }
                if fm.fileExists(atPath: target.path(percentEncoded: false)) {
                    sink.totals.declaredBytes -= header.declaredSize ?? 0
                    sink.totals.skipped += 1
                    continue
                }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let fd = Darwin.open(target.path(percentEncoded: false), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                guard fd >= 0 else { throw ExtractionError.write(path: relative, errno: errno) }
                defer { Darwin.close(fd) }
                sink.fd = fd
                sink.path = relative
                sink.remaining = header.declaredSize ?? 0
                let code = op_cab_extract(cab, Int32(index), { context, bytes, count in
                    guard let context, let bytes else { return -1 }
                    let sink = Unmanaged<CabSink>.fromOpaque(context).takeUnretainedValue()
                    do { try sink.write(bytes, count: count); return 0 } catch { sink.failure = error; return -1 }
                }, Unmanaged.passUnretained(sink).toOpaque())
                if let failure = sink.failure {
                    throw failure
                }
                guard code == 0 else { throw ExtractionError.entry(path: relative, message: "cabinet error \(code)") }
                guard sink.remaining == 0 else {
                    throw SafetyViolation(rule: .sizeMismatch, entryPath: relative, detail: "cabinet entry shorter than declared")
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

private final class CabSink {
    let validator: EntryValidator
    let sourceBytes: Int64
    let progress: (@Sendable (Int64, String) -> Void)?
    var totals = RunningTotals()
    var fd: Int32 = -1
    var path = ""
    var remaining: Int64 = 0
    var failure: Error?

    init(validator: EntryValidator, sourceBytes: Int64, progress: (@Sendable (Int64, String) -> Void)?) {
        self.validator = validator; self.sourceBytes = sourceBytes; self.progress = progress
    }

    func write(_ bytes: UnsafeRawPointer, count: Int) throws {
        try Task.checkCancellation()
        guard count <= remaining else {
            throw SafetyViolation(rule: .sizeMismatch, entryPath: path, detail: "cabinet entry exceeds declared size")
        }
        totals.writtenBytes += Int64(count)
        if let violation = validator.checkWritten(totals, sourceBytes: sourceBytes) {
            throw violation
        }
        var offset = 0
        while offset < count {
            let written = Darwin.write(fd, bytes.advanced(by: offset), count - offset)
            if written < 0, errno == EINTR {
                continue
            }
            guard written > 0 else { throw ExtractionError.write(path: path, errno: errno) }
            offset += written
        }
        remaining -= Int64(count)
        progress?(totals.writtenBytes, path)
    }
}
