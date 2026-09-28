import CUnrar
import Darwin
import Foundation

/// UnRAR only decodes. OmniPlay validates names and owns every output write.
public struct RarExtractor: Sendable {
    public let limits: SafetyLimits
    public init(limits: SafetyLimits = .default) { self.limits = limits }

    public func preflight(_ url: URL, passphrase: String? = nil) throws -> ArchivePreflight {
        let reader = try open(url, passphrase: passphrase)
        defer { op_rar_close(reader) }
        var result = ArchivePreflight()
        var totals = RunningTotals()
        while let entry = try next(reader) {
            try Task.checkCancellation()
            let header = try header(entry)
            if case let .reject(error) = EntryValidator(limits: limits).validate(header, running: &totals) {
                throw error
            }
            result.entries += 1
            result.declaredBytes = totals.declaredBytes
            result.encrypted = result.encrypted || entry.encrypted != 0
            try check(op_rar_process(reader, 1, nil, nil), reader: reader, path: header.path)
        }
        return result
    }

    public func extract(
        _ url: URL, to destination: URL, passphrase: String? = nil,
        progress: (@Sendable (Int64, String) -> Void)? = nil
    ) throws -> RunningTotals {
        let reader = try open(url, passphrase: passphrase)
        defer { op_rar_close(reader) }
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let validator = EntryValidator(limits: limits)
        let sink = try RarSink(validator: validator, sourceBytes: Self.sourceBytes(url), progress: progress)
        while let entry = try next(reader) {
            try Task.checkCancellation()
            let header = try header(entry)
            switch validator.validate(header, running: &sink.totals) {
            case let .reject(error): throw error
            case .skip:
                try check(op_rar_process(reader, 1, nil, nil), reader: reader, path: header.path)
            case let .extract(relative):
                let target = destination.appending(path: relative)
                let rootPath = destination.resolvingSymlinksInPath().pathComponents
                let targetPath = target.resolvingSymlinksInPath().pathComponents
                guard targetPath.count > rootPath.count, targetPath.starts(with: rootPath) else {
                    throw SafetyViolation(rule: .invalidPath, entryPath: relative, detail: "symlink escapes staging")
                }
                if header.kind == .directory {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                    try check(op_rar_process(reader, 1, nil, nil), reader: reader, path: relative)
                    continue
                }
                if fm.fileExists(atPath: target.path(percentEncoded: false)) {
                    sink.totals.declaredBytes -= header.declaredSize ?? 0
                    sink.totals.skipped += 1
                    try check(op_rar_process(reader, 1, nil, nil), reader: reader, path: relative)
                    continue
                }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let fd = Darwin.open(target.path(percentEncoded: false), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                guard fd >= 0 else { throw ExtractionError.write(path: relative, errno: errno) }
                defer { Darwin.close(fd) }
                sink.fd = fd
                sink.path = relative
                sink.remaining = header.declaredSize ?? 0
                let code = op_rar_process(reader, 0, { context, bytes, count in
                    guard let context, let bytes else { return -1 }
                    let sink = Unmanaged<RarSink>.fromOpaque(context).takeUnretainedValue()
                    do { try sink.write(bytes, count: count); return 0 } catch { sink.failure = error; return -1 }
                }, Unmanaged.passUnretained(sink).toOpaque())
                if let failure = sink.failure {
                    throw failure
                }
                try check(code, reader: reader, path: relative)
                guard sink.remaining == 0 else {
                    throw SafetyViolation(rule: .sizeMismatch, entryPath: relative, detail: "RAR entry shorter than declared")
                }
            }
        }
        return sink.totals
    }

    private func open(_ url: URL, passphrase: String?) throws -> OpaquePointer {
        try Task.checkCancellation()
        var code: Int32 = 0
        let reader = op_rar_open(url.path(percentEncoded: false), passphrase, &code)
        guard let reader else { try check(code, reader: nil, path: url.lastPathComponent); throw ExtractionError.open("UnRAR open failed") }
        return reader
    }

    private func next(_ reader: OpaquePointer) throws -> OPRarEntry? {
        var entry = OPRarEntry()
        let code = op_rar_next(reader, &entry)
        if code == 10 {
            return nil
        }
        try check(code, reader: reader, path: "(header)")
        return entry
    }

    private func header(_ entry: OPRarEntry) throws -> ArchiveEntryHeader {
        let path = String(cString: entry.path)
        guard entry.size <= UInt64(Int64.max) else {
            throw SafetyViolation(rule: .declaredSize, entryPath: path, detail: "RAR size exceeds supported range")
        }
        // Bound the native decoder too: small callback buffers do not bound its dictionary.
        guard entry.dictionaryKiB <= 64 * 1024 else {
            throw ExtractionError.unsupportedCompression(path: path, message: "RAR dictionary exceeds the 64 MiB import limit")
        }
        guard entry.splitBefore == 0 else {
            throw ImportFailure.extractionFailed(entry: path, underlying: "Choose the first RAR volume and keep all volumes together.")
        }
        return ArchiveEntryHeader(
            path: path,
            kind: entry.kind == 0 ? .file : entry.kind == 1 ? .directory : .other,
            declaredSize: Int64(entry.size)
        )
    }

    private func check(_ code: Int32, reader: OpaquePointer?, path: String) throws {
        guard code != 0 else { return }
        if let reader {
            let missing = String(cString: op_rar_missing_volume(reader))
            if !missing.isEmpty {
                throw ImportFailure.missingVolume(URL(filePath: missing).lastPathComponent)
            }
        }
        switch code {
        case 22: throw ImportFailure.passwordRequired
        case 24: throw ImportFailure.passwordIncorrect
        default: throw ExtractionError.entry(path: path, message: "UnRAR error \(code)")
        }
    }

    /// Include the neighboring volumes in the ratio denominator; do not charge a whole set against part 1.
    public static func sourceBytes(_ url: URL) throws -> Int64 {
        let name = url.lastPathComponent
        let pattern: String
        if let range = name.range(of: #"\.part\d+\.rar$"#, options: [.regularExpression, .caseInsensitive]) {
            pattern = "^" + NSRegularExpression.escapedPattern(for: String(name[..<range.lowerBound])) + #"\.part\d+\.rar$"#
        } else if url.pathExtension.lowercased() == "rar" {
            pattern = "^" + NSRegularExpression.escapedPattern(for: url.deletingPathExtension().lastPathComponent) + #"\.(rar|r\d{2})$"#
        } else {
            return try Int64(url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let directory = url.deletingLastPathComponent()
        guard let entries = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsSubdirectoryDescendants]
        ) else { return 0 }
        var bytes: Int64 = 0
        for case let sibling as URL in entries {
            try Task.checkCancellation()
            try autoreleasepool {
                let name = sibling.lastPathComponent
                if regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil {
                    try bytes += Int64(sibling.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                }
            }
        }
        return bytes
    }
}

private final class RarSink {
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
            throw SafetyViolation(rule: .sizeMismatch, entryPath: path, detail: "RAR entry exceeds declared size")
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
