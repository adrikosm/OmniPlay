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
        let sink = try StreamingSink(label: "RAR", validator: validator, sourceBytes: Self.sourceBytes(url), progress: progress)
        while let entry = try next(reader) {
            try Task.checkCancellation()
            let header = try header(entry)
            switch validator.validate(header, running: &sink.totals) {
            case let .reject(error): throw error
            case .skip:
                try check(op_rar_process(reader, 1, nil, nil), reader: reader, path: header.path)
            case let .extract(relative):
                let target = try StreamingSink.target(relative, in: destination)
                if header.kind == .directory {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                    try check(op_rar_process(reader, 1, nil, nil), reader: reader, path: relative)
                    continue
                }
                if sink.skipsDuplicate(target, declaredSize: header.declaredSize) {
                    try check(op_rar_process(reader, 1, nil, nil), reader: reader, path: relative)
                    continue
                }
                try sink.stream(to: target, path: relative, declaredSize: header.declaredSize) { callback, context in
                    try check(op_rar_process(reader, 0, callback, context), reader: reader, path: relative)
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

/// UnRAR and libmspack only decode: each streams an entry's bytes through a C callback into this sink, which owns
/// the output file and judges every block against the declared size and the running limits.
final class StreamingSink {
    typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, Int) -> Int32
    let label: String
    let validator: EntryValidator
    let sourceBytes: Int64
    let progress: (@Sendable (Int64, String) -> Void)?
    var totals = RunningTotals()
    private var fd: Int32 = -1
    private var path = ""
    private var remaining: Int64 = 0
    private var failure: Error?

    init(label: String, validator: EntryValidator, sourceBytes: Int64, progress: (@Sendable (Int64, String) -> Void)?) {
        self.label = label; self.validator = validator; self.sourceBytes = sourceBytes; self.progress = progress
    }

    /// The entry's staging target; refuses one that a staged symlink would carry outside `destination`.
    static func target(_ relative: String, in destination: URL) throws -> URL {
        let target = destination.appending(path: relative)
        let rootPath = destination.resolvingSymlinksInPath().pathComponents
        let targetPath = target.resolvingSymlinksInPath().pathComponents
        guard targetPath.count > rootPath.count, targetPath.starts(with: rootPath) else {
            throw SafetyViolation(rule: .invalidPath, entryPath: relative, detail: "symlink escapes staging")
        }
        return target
    }

    /// First wins: a later entry with a name already written is skipped, and its declared bytes released.
    func skipsDuplicate(_ target: URL, declaredSize: Int64?) -> Bool {
        guard FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else { return false }
        totals.declaredBytes -= declaredSize ?? 0
        totals.skipped += 1
        return true
    }

    /// Creates `target` exclusively and lets `decode` stream into it. A write failure wins over the decoder's error.
    func stream(
        to target: URL,
        path relative: String,
        declaredSize: Int64?,
        decode: (Callback, UnsafeMutableRawPointer) throws -> Void
    ) throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(target.path(percentEncoded: false), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ExtractionError.write(path: relative, errno: errno) }
        defer { Darwin.close(fd) }
        self.fd = fd
        path = relative
        remaining = declaredSize ?? 0
        do {
            try decode({ context, bytes, count in
                guard let context, let bytes else { return -1 }
                let sink = Unmanaged<StreamingSink>.fromOpaque(context).takeUnretainedValue()
                do { try sink.write(bytes, count: count); return 0 } catch { sink.failure = error; return -1 }
            }, Unmanaged.passUnretained(self).toOpaque())
        } catch {
            throw failure ?? error
        }
        if let failure {
            throw failure
        }
        guard remaining == 0 else {
            throw SafetyViolation(rule: .sizeMismatch, entryPath: relative, detail: "\(label) entry shorter than declared")
        }
    }

    private func write(_ bytes: UnsafeRawPointer, count: Int) throws {
        try Task.checkCancellation()
        guard count <= remaining else {
            throw SafetyViolation(rule: .sizeMismatch, entryPath: path, detail: "\(label) entry exceeds declared size")
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
