import CryptoKit
import Diagnostics
import Foundation
import GameCore

/// Makes committed originals read-only and verifiable: `chmod 0444` files, `0555` directories, and a streamed
/// manifest (`size\tsha256\trel_path`, one line per file). Installations above 8 GiB defer hashing to a
/// background pass and carry `-` until then.
public enum OriginalGuard {
    public enum HashingMode: Sendable { case immediate, deferred }
    public static let deferredThreshold: Int64 = 8 << 30

    public struct SealSummary: Sendable, Hashable {
        public let files: Int
        public let bytes: Int64
        public let hashed: Bool
    }

    public struct VerifyResult: Sendable, Hashable {
        public let checked: Int
        public let mismatched: [String]
        public let skippedUnhashed: Int
        public var ok: Bool { mismatched.isEmpty }
    }

    public static func isSealed(manifest: URL) -> Bool { FileManager.default.fileExists(atPath: manifest.path()) }

    /// `hashing == nil` picks immediate below `deferredThreshold`, deferred above. Runs on the caller's task; cancellable.
    @discardableResult
    public static func seal(originalRoot: URL, manifest: URL, hashing: HashingMode? = nil) throws -> SealSummary {
        let mode: HashingMode = hashing ?? (treeSize(originalRoot) > deferredThreshold ? .deferred : .immediate)
        let fm = FileManager.default
        try fm.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = manifest.appendingPathExtension("part")
        _ = fm.createFile(atPath: temp.path(), contents: nil)
        let out = try FileHandle(forWritingTo: temp)
        var files = 0
        var bytes: Int64 = 0
        do {
            try LazyDirectoryWalker.walk(root: originalRoot, skipHidden: false) { entry in
                try Task.checkCancellation()
                if entry.isDirectory {
                    try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: entry.url.path(percentEncoded: false))
                    return .continue
                }
                let hash = mode == .immediate ? try StreamingHasher.sha256(of: entry.url).hex : "-"
                try out.write(contentsOf: Data("\(entry.fileSize)\t\(hash)\t\(entry.relativePath)\n".utf8))
                try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: entry.url.path(percentEncoded: false))
                files += 1
                bytes += entry.fileSize
                return .continue
            }
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: originalRoot.path(percentEncoded: false))
            try out.close()
            if fm.fileExists(atPath: manifest.path()) {
                _ = try fm.replaceItemAt(manifest, withItemAt: temp)
            } else {
                try fm.moveItem(
                    at: temp,
                    to: manifest
                )
            }
        } catch {
            try? out.close()
            try? fm.removeItem(at: temp)
            try? unseal(originalRoot: originalRoot)
            throw error
        }
        OPLog.log(.filesystem, .info, "sealed \(files) files, \(bytes) bytes, hashed=\(mode == .immediate)")
        return SealSummary(files: files, bytes: bytes, hashed: mode == .immediate)
    }

    /// Fills in the `-` hashes of a deferred manifest, streaming line by line into a temp file, then swaps it in.
    public static func completeDeferredHashing(originalRoot: URL, manifest: URL) async throws {
        let temp = manifest.appendingPathExtension("rehash")
        _ = FileManager.default.createFile(atPath: temp.path(), contents: nil)
        let out = try FileHandle(forWritingTo: temp)
        do {
            for try await line in manifest.lines {
                try Task.checkCancellation()
                let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3 else { continue }
                var hash = String(parts[1])
                if hash == "-" {
                    hash = try StreamingHasher.sha256(of: originalRoot.appending(path: String(parts[2]))).hex
                }
                try out.write(contentsOf: Data("\(parts[0])\t\(hash)\t\(parts[2])\n".utf8))
            }
            try out.close()
            _ = try FileManager.default.replaceItemAt(manifest, withItemAt: temp)
        } catch {
            try? out.close()
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// Re-hashes a bounded random sample of manifest entries (reservoir sampling over the streamed manifest).
    public static func verify(originalRoot: URL, manifest: URL, sample: Int = 64) async throws -> VerifyResult {
        var reservoir: [(String, String)] = []
        var seen = 0
        var unhashed = 0
        var rng = SystemRandomNumberGenerator()
        for try await line in manifest.lines {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            if parts[1] == "-" {
                unhashed += 1; continue
            }
            seen += 1
            let item = (String(parts[1]), String(parts[2]))
            if reservoir.count < sample {
                reservoir.append(item)
            } else {
                let j = Int.random(in: 0 ..< seen, using: &rng)
                if j < sample {
                    reservoir[j] = item
                }
            }
        }
        var mismatched: [String] = []
        for (hash, rel) in reservoir {
            try Task.checkCancellation()
            let url = originalRoot.appending(path: rel)
            if (try? StreamingHasher.sha256(of: url).hex) != hash {
                mismatched.append(rel)
            }
        }
        return VerifyResult(checked: reservoir.count, mismatched: mismatched, skippedUnhashed: unhashed)
    }

    /// Restores write permission (needed before deleting a game).
    public static func unseal(originalRoot: URL) throws {
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: originalRoot.path(percentEncoded: false))
        try LazyDirectoryWalker.walk(root: originalRoot, skipHidden: false) { entry in
            try fm.setAttributes(
                [.posixPermissions: entry.isDirectory ? 0o755 : 0o644],
                ofItemAtPath: entry.url.path(percentEncoded: false)
            )
            return .continue
        }
    }

    private static func treeSize(_ root: URL) -> Int64 {
        var total: Int64 = 0
        try? LazyDirectoryWalker.walk(root: root, skipHidden: false) { total += $0.fileSize; return .continue }
        return total
    }
}
