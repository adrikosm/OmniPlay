import CLibArchive
import Diagnostics
import Foundation
import GameCore

public struct ArchivePreflight: Sendable, Hashable {
    public var entries = 0
    public var declaredBytes: Int64 = 0
    public var sizesKnown = true
    public var encrypted = false
    /// Some entry names could not be decoded as UTF-8; retry with `hdrcharset: "CP932"`.
    public var undecodableNames = false
}

public enum ExtractionError: Error, Sendable, Hashable {
    case open(String)
    case entry(path: String, message: String)
    case unsupportedCompression(path: String, message: String)
    case write(path: String, errno: Int32)
}

/// Streams ZIP, 7z and tar (gzip/bzip2/xz/zstd) into a directory with bounded buffers. libarchive owns the
/// read buffers; each data block goes straight to `pwrite`, so the footprint stays at libarchive's own
/// working set no matter how large the archive. Cancel the surrounding Task to abort.
public struct LibArchiveExtractor: Sendable {
    public let limits: SafetyLimits

    public init(limits: SafetyLimits = .default) { self.limits = limits }

    /// Headers only: sums declared sizes for the disk precheck and reports encryption and name problems.
    /// `offset` reads the archive appended to a Windows executable in place.
    public func preflight(_ url: URL, hdrcharset: String? = nil, offset: Int64 = 0) throws -> ArchivePreflight {
        let a = try open(url, hdrcharset: hdrcharset, passphrase: nil, offset: offset)
        defer { archive_read_free(a) }
        var result = ArchivePreflight()
        var entry: OpaquePointer?
        while true {
            // A compressed tar decompresses the whole stream to list it; Cancel must not wait for that.
            try Task.checkCancellation()
            let r = archive_read_next_header(a, &entry)
            if r == ARCHIVE_EOF {
                break
            }
            if r == ARCHIVE_WARN {
                OPLog.log(.importer, .default, "libarchive: \(errorString(a))")
            } else if r != ARCHIVE_OK {
                throw ExtractionError.entry(path: "(header)", message: errorString(a))
            }
            guard let entry else { continue }
            result.entries += 1
            if archive_entry_pathname_utf8(entry) == nil {
                result.undecodableNames = true
            }
            if archive_entry_size_is_set(entry) != 0 {
                // ZIP64 headers can declare up to 2^63; refuse here, before the sum or the disk budget overflows.
                let size = Int64(archive_entry_size(entry))
                guard size >= 0, size <= Int64(clamping: limits.maxUncompressedBytes) - result.declaredBytes else {
                    throw SafetyViolation(
                        rule: .declaredSize,
                        detail: "declared total exceeds \(limits.maxUncompressedBytes) bytes"
                    )
                }
                result.declaredBytes += size
            } else {
                result.sizesKnown = false
            }
            if archive_entry_is_encrypted(entry) != 0 {
                result.encrypted = true
            }
            if result.entries > limits.maxEntries {
                break
            }
        }
        if archive_read_has_encrypted_entries(a) > 0 {
            result.encrypted = true
        }
        return result
    }

    /// Extracts every regular file and directory that passes the safety policy. Returns the running totals
    /// for `PostExtractionAudit`. Duplicate names keep the first entry.
    public func extract(
        _ url: URL,
        to destination: URL,
        passphrase: String? = nil,
        hdrcharset: String? = nil,
        offset: Int64 = 0,
        progress: (@Sendable (Int64, String) -> Void)? = nil
    ) throws -> RunningTotals {
        let sourceBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) - offset }
        let a = try open(url, hdrcharset: hdrcharset, passphrase: passphrase, offset: offset)
        defer { archive_read_free(a) }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let validator = EntryValidator(limits: limits)
        var totals = RunningTotals()
        var entry: OpaquePointer?
        while true {
            try Task.checkCancellation()
            let r = archive_read_next_header(a, &entry)
            if r == ARCHIVE_EOF {
                break
            }
            if r == ARCHIVE_WARN {
                OPLog.log(.importer, .default, "libarchive: \(errorString(a))")
            } else if r != ARCHIVE_OK {
                throw Self.classify(errorString(a), path: "(header)")
            }
            guard let entry else { continue }
            guard let rawPath = archive_entry_pathname_utf8(entry).map({ String(cString: $0) })
                ?? archive_entry_pathname(entry).map({ String(cString: $0) })
            else {
                throw SafetyViolation(
                    rule: .invalidPath,
                    entryPath: nil,
                    detail: "entry name cannot be decoded; retry with a header charset"
                )
            }
            let declared: Int64? = archive_entry_size_is_set(entry) != 0 ? Int64(archive_entry_size(entry)) : nil
            let header = ArchiveEntryHeader(path: rawPath, kind: Self.kind(archive_entry_filetype(entry)), declaredSize: declared)
            switch validator.validate(header, running: &totals) {
            case let .reject(v): throw v
            case .skip: archive_read_data_skip(a)
            case let .extract(rel):
                let target = destination.appending(path: rel)
                if header.kind == .directory {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                    continue
                }
                if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
                    OPLog.log(.importer, .default, "duplicate entry \(rel): keeping the first")
                    // Its size is not on disk; the audit compares declared with written bytes (CAB and RAR do the same).
                    totals.declaredBytes -= header.declaredSize ?? 0
                    totals.skipped += 1
                    archive_read_data_skip(a)
                    continue
                }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                // The running limits are judged per block, so one huge zero entry stops near the ratio floor, not at 16 GiB.
                var running = totals
                let before = totals.writtenBytes
                totals.writtenBytes += try writeEntry(a, to: target, declared: header.declaredSize, path: rel) { written in
                    running.writtenBytes = before + written
                    return validator.checkWritten(running, sourceBytes: sourceBytes)
                }
                let mtime = archive_entry_mtime(entry)
                if mtime > 0 {
                    let date = Date(timeIntervalSince1970: TimeInterval(mtime))
                    try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: target.path(percentEncoded: false))
                }
                progress?(totals.writtenBytes, rel)
            }
        }
        return totals
    }

    // MARK: - Internals

    /// libarchive decodes entry names into the process locale's charset; a bare process starts in the ASCII
    /// "C" locale and every non-ASCII name would fail, so the C type locale is set to UTF-8 once.
    private static let utf8Locale: Bool = setlocale(LC_CTYPE, "UTF-8") != nil

    private func open(_ url: URL, hdrcharset: String?, passphrase: String?, offset: Int64 = 0) throws -> OpaquePointer {
        _ = Self.utf8Locale
        guard let a = archive_read_new() else { throw ExtractionError.open("archive_read_new failed") }
        archive_read_support_format_zip(a)
        archive_read_support_format_7zip(a)
        archive_read_support_format_tar(a)
        archive_read_support_format_cab(a)
        archive_read_support_format_rar(a)
        archive_read_support_format_rar5(a)
        archive_read_support_filter_gzip(a)
        archive_read_support_filter_bzip2(a)
        archive_read_support_filter_xz(a)
        archive_read_support_filter_zstd(a)
        if let hdrcharset {
            archive_read_set_options(a, "hdrcharset=\(hdrcharset)")
        }
        if let passphrase {
            archive_read_add_passphrase(a, passphrase)
        }
        let opened: Int32
        if offset == 0 {
            opened = archive_read_open_filename(a, url.path(percentEncoded: false), 64 << 10)
        } else {
            guard let client = ArchiveWindow(url: url, offset: offset)
            else { archive_read_free(a); throw ExtractionError.open("cannot open \(url.lastPathComponent)") }
            // The seek callback must be registered while the archive is still in its new state, before open2.
            archive_read_set_seek_callback(a) { a, d, o, w in ArchiveWindow.seekCallback(a, d, o, w) }
            opened = archive_read_open2(
                a,
                Unmanaged.passRetained(client).toOpaque(),
                nil,
                { a, d, o in ArchiveWindow.readCallback(a, d, o) },
                { a, d, r in ArchiveWindow.skipCallback(a, d, r) },
                { a, d in ArchiveWindow.closeCallback(a, d) }
            )
        }
        guard opened == ARCHIVE_OK else {
            let message = errorString(a)
            archive_read_free(a)
            throw ExtractionError.open(message)
        }
        return a
    }

    /// Streams one entry's blocks to disk. Blocks are libarchive's buffers written in place with `pwrite`.
    private func writeEntry(
        _ a: OpaquePointer,
        to target: URL,
        declared: Int64?,
        path: String,
        check: (Int64) -> SafetyViolation?
    ) throws -> Int64 {
        let fd = Darwin.open(target.path(percentEncoded: false), O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { throw ExtractionError.write(path: path, errno: errno) }
        defer { close(fd) }
        var written: Int64 = 0
        var buffer: UnsafeRawPointer?
        var size = 0
        var offset: la_int64_t = 0
        while true {
            try Task.checkCancellation()
            let r = archive_read_data_block(a, &buffer, &size, &offset)
            if r == ARCHIVE_EOF {
                break
            }
            if r == ARCHIVE_WARN {
                OPLog.log(.importer, .default, "libarchive \(path): \(errorString(a))")
            } else if r != ARCHIVE_OK {
                throw Self.classify(errorString(a), path: path)
            }
            guard let buffer, size > 0 else { continue }
            if let declared, Int64(offset) + Int64(size) > declared {
                throw SafetyViolation(rule: .sizeMismatch, entryPath: path, detail: "entry writes past its declared \(declared) bytes")
            }
            var done = 0
            while done < size {
                let n = pwrite(fd, buffer + done, size - done, off_t(offset) + off_t(done))
                if n < 0 {
                    throw errno == ENOSPC ? StorageError.insufficientSpace(
                        required: declared ?? 0,
                        available: (try? VolumeSpace.available(at: target)) ?? 0,
                        reason: "extract \(path)"
                    ) : ExtractionError.write(path: path, errno: errno)
                }
                done += Int(n)
            }
            written = max(written, Int64(offset) + Int64(size))
            if let v = check(written) {
                throw v
            }
        }
        return written
    }

    private func errorString(_ a: OpaquePointer) -> String {
        archive_error_string(a).map { String(cString: $0) } ?? "unknown libarchive error"
    }

    private static func classify(_ message: String, path: String) -> Error {
        message.lowercased().contains("deflate64") || message.contains("method (9")
            ? ExtractionError.unsupportedCompression(
                path: path,
                message: "compression method 9 (Deflate64) is unsupported; re-zip with standard deflate"
            )
            : ExtractionError.entry(path: path, message: message)
    }

    private static func kind(_ mode: mode_t) -> ArchiveEntryHeader.Kind {
        switch mode & S_IFMT {
        case S_IFREG: .file
        case S_IFDIR: .directory
        case S_IFLNK: .symlink
        case S_IFCHR, S_IFBLK, S_IFIFO, S_IFSOCK: .device
        default: .other
        }
    }
}

/// A byte window `[offset, EOF)` of a file presented to libarchive through its client callbacks, so an archive
/// appended to an executable is read in place. One 1 MiB buffer; libarchive owns nothing else.
final class ArchiveWindow {
    static let bufferSize = 1 << 20
    let fd: Int32
    let start: Int64
    let end: Int64
    var position: Int64
    let buffer: UnsafeMutableRawPointer

    init?(url: URL, offset: Int64) {
        fd = Darwin.open(url.path(percentEncoded: false), O_RDONLY)
        guard fd >= 0 else { return nil }
        var st = stat()
        fstat(fd, &st)
        start = offset
        end = Int64(st.st_size)
        position = offset
        buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 16)
    }

    deinit {
        Darwin.close(fd)
        buffer.deallocate()
    }

    static func from(_ data: UnsafeMutableRawPointer?) -> ArchiveWindow? {
        data.map { Unmanaged<ArchiveWindow>.fromOpaque($0).takeUnretainedValue() }
    }

    static func readCallback(
        _: OpaquePointer?,
        _ data: UnsafeMutableRawPointer?,
        _ out: UnsafeMutablePointer<UnsafeRawPointer?>?
    ) -> la_ssize_t {
        guard let w = from(data), let out else { return -1 }
        let want = Int(min(Int64(bufferSize), w.end - w.position))
        guard want > 0 else { out.pointee = UnsafeRawPointer(w.buffer); return 0 }
        let n = pread(w.fd, w.buffer, want, off_t(w.position))
        if n > 0 {
            w.position += Int64(n)
        }
        out.pointee = UnsafeRawPointer(w.buffer)
        return la_ssize_t(n)
    }

    static func skipCallback(_: OpaquePointer?, _ data: UnsafeMutableRawPointer?, _ request: la_int64_t) -> la_int64_t {
        guard let w = from(data) else { return 0 }
        let n = min(request, w.end - w.position)
        w.position += n
        return n
    }

    static func seekCallback(_: OpaquePointer?, _ data: UnsafeMutableRawPointer?, _ offset: la_int64_t, _ whence: Int32) -> la_int64_t {
        guard let w = from(data) else { return -1 }
        let base: Int64 = switch whence {
        case SEEK_SET: w.start
        case SEEK_CUR: w.position
        default: w.end
        }
        let target = base + offset
        guard target >= w.start, target <= w.end else { return -1 }
        w.position = target
        return target - w.start
    }

    static func closeCallback(_: OpaquePointer?, _ data: UnsafeMutableRawPointer?) -> Int32 {
        if let data {
            Unmanaged<ArchiveWindow>.fromOpaque(data).release()
        }
        return ARCHIVE_OK
    }
}
