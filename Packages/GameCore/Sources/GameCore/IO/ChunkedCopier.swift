import CryptoKit
import Foundation

/// Streaming copy: 1 MiB chunks, temp file plus rename, `fsync` at the end. Cancel the surrounding
/// `Task` to abort; the partial destination is removed. Peak memory is one chunk.
public enum ChunkedCopier {
    public static let defaultChunk = 1 << 20

    public static func copy(
        from source: URL,
        to destination: URL,
        chunk: Int = defaultChunk,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) async throws {
        let temp = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).part-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        _ = fm.createFile(atPath: temp.path(), contents: nil)
        let output = try FileHandle(forWritingTo: temp)
        var copied: Int64 = 0
        do {
            // Each chunk lives in its own autorelease pool: FileHandle returns autoreleased NSData and a
            // long loop would otherwise hold every chunk until the pool drains.
            while try autoreleasepool(invoking: { () throws -> Bool in
                guard let data = try input.read(upToCount: chunk), !data.isEmpty else { return false }
                try Task.checkCancellation()
                try output.write(contentsOf: data)
                copied += Int64(data.count)
                progress?(copied)
                return true
            }) {}
            try output.synchronize()
            try output.close()
            if fm.fileExists(atPath: destination.path()) {
                _ = try fm.replaceItemAt(destination, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: destination)
            }
        } catch {
            try? output.close()
            try? fm.removeItem(at: temp)
            let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            throw StorageError.map(error, required: size, at: destination)
        }
    }
}

public enum StreamingHasher {
    public static func sha256(
        of url: URL,
        chunk: Int = ChunkedCopier.defaultChunk,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) throws -> SHA256Digest {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256()
        var read: Int64 = 0
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let data = try input.read(upToCount: chunk), !data.isEmpty else { return false }
            try Task.checkCancellation()
            hasher.update(data: data)
            read += Int64(data.count)
            progress?(read)
            return true
        }) {}
        return hasher.finalize()
    }
}

public extension SHA256Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// Reads at most 64 KiB from the start of a file, for magic sniffing.
public enum BoundedReader {
    public static let maxHeader = 64 << 10

    public static func readHeader(url: URL, bytes: Int) throws -> Data {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        return try h.read(upToCount: min(bytes, maxHeader)) ?? Data()
    }
}

/// `clonefile(2)` where the volume supports it, streaming copy otherwise.
public enum APFSClone {
    public static func clone(from source: URL, to destination: URL) async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if clonefile(source.path(percentEncoded: false), destination.path(percentEncoded: false), 0) == 0 {
            return
        }
        if errno == ENOSPC {
            throw StorageError.insufficientSpace(
                required: 0,
                available: (try? VolumeSpace.available(at: destination)) ?? 0,
                reason: "clone"
            )
        }
        try await ChunkedCopier.copy(from: source, to: destination)
    }
}
