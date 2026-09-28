import CLibArchive
import Diagnostics
import Foundation
import GameCore

public enum ArchiveWriteError: Error, Sendable, Hashable {
    case open(String)
    case entry(path: String, message: String)
    case read(path: String)
    case close(String)
}

/// Streams a directory into a ZIP (deflate) with libarchive: one entry at a time, 1 MiB blocks, so the footprint
/// does not depend on the size of the tree. Always ZIP, never RAR.
public struct ArchiveWriter: Sendable {
    public static let blockSize = 1 << 20

    public init() {}

    /// Writes every regular file under `directory` as `prefix/<relative path>`; `extras` are small in-memory members
    /// (a manifest) added first. Returns the number of entries written.
    @discardableResult
    public func zip(
        directory: URL,
        to destination: URL,
        prefix: String = "",
        extras: [(name: String, data: Data)] = [],
        progress: (@Sendable (Int64, String) -> Void)? = nil
    ) throws -> Int {
        guard let a = archive_write_new() else { throw ArchiveWriteError.open("archive_write_new failed") }
        defer { archive_write_free(a) }
        archive_write_set_format_zip(a)
        archive_write_set_options(a, "zip:compression=deflate,zip:zip64")
        guard archive_write_open_filename(a, destination.path(percentEncoded: false)) == ARCHIVE_OK else {
            throw ArchiveWriteError.open(Self.errorString(a))
        }
        // A half-written ZIP in Files looks like a finished export; remove it on any failure or cancellation.
        var complete = false
        defer {
            if !complete {
                try? FileManager.default.removeItem(at: destination)
            }
        }
        var count = 0
        var written: Int64 = 0
        for extra in extras {
            try Self.add(a, name: Self.join(prefix, extra.name), size: Int64(extra.data.count), mtime: .now) { emit in
                try extra.data.withUnsafeBytes { try emit($0) }
            }
            count += 1
        }
        var files: [RelativeEntry] = []
        try LazyDirectoryWalker.walk(root: directory) { entry in
            if !entry.isDirectory {
                files.append(entry)
            }
            return .continue
        }
        for file in files.sorted(by: { $0.relativePath < $1.relativePath }) {
            try Task.checkCancellation()
            let mtime = (try? file.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now
            try Self.add(a, name: Self.join(prefix, file.relativePath), size: file.fileSize, mtime: mtime) { emit in
                let handle = try FileHandle(forReadingFrom: file.url)
                defer { try? handle.close() }
                while true {
                    let chunk = try autoreleasepool { try handle.read(upToCount: Self.blockSize) } ?? Data()
                    if chunk.isEmpty {
                        break
                    }
                    try chunk.withUnsafeBytes { try emit($0) }
                }
            }
            written += file.fileSize
            count += 1
            progress?(written, file.relativePath)
        }
        // The ZIP central directory is written on close: a failure here (a full disk) leaves an unreadable archive.
        // On the error paths above, `archive_write_free` closes the archive itself.
        guard archive_write_close(a) == ARCHIVE_OK else { throw ArchiveWriteError.close(Self.errorString(a)) }
        complete = true
        return count
    }

    private static func add(
        _ a: OpaquePointer,
        name: String,
        size: Int64,
        mtime: Date,
        body: ((UnsafeRawBufferPointer) throws -> Void) throws -> Void
    ) throws {
        guard let entry = archive_entry_new() else { throw ArchiveWriteError.entry(path: name, message: "archive_entry_new failed") }
        defer { archive_entry_free(entry) }
        archive_entry_set_pathname_utf8(entry, name)
        archive_entry_set_size(entry, la_int64_t(size))
        archive_entry_set_filetype(entry, UInt32(S_IFREG))
        archive_entry_set_perm(entry, 0o644)
        archive_entry_set_mtime(entry, time_t(mtime.timeIntervalSince1970), 0)
        guard archive_write_header(a, entry) == ARCHIVE_OK else { throw ArchiveWriteError.entry(path: name, message: errorString(a)) }
        try body { buffer in
            guard let base = buffer.baseAddress, !buffer.isEmpty else { return }
            guard archive_write_data(a, base, buffer.count) >= 0 else { throw ArchiveWriteError.entry(path: name, message: errorString(a)) }
        }
    }

    private static func join(_ prefix: String, _ name: String) -> String { prefix.isEmpty ? name : "\(prefix)/\(name)" }

    private static func errorString(_ a: OpaquePointer) -> String { archive_error_string(a)
        .map { String(cString: $0) } ?? "unknown libarchive error"
    }
}
