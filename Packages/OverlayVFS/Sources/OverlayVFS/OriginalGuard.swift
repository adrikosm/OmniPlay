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

    public static func isSealed(manifest: URL) -> Bool { FileManager.default.fileExists(atPath: manifest.path(percentEncoded: false)) }

    /// `hashing == nil` picks immediate below `deferredThreshold`, deferred above. Runs on the caller's task; cancellable.
    @discardableResult
    public static func seal(originalRoot: URL, manifest: URL, hashing: HashingMode? = nil) throws -> SealSummary {
        let mode: HashingMode = hashing ?? (treeSize(originalRoot) > deferredThreshold ? .deferred : .immediate)
        let fm = FileManager.default
        try fm.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = manifest.appendingPathExtension("part")
        _ = fm.createFile(atPath: temp.path(percentEncoded: false), contents: nil)
        let out = try FileHandle(forWritingTo: temp)
        var files = 0
        var bytes: Int64 = 0
        // Lines go out in 64 KiB writes, not one write per file: a game of tens of thousands of small files paid a
        // system call for each.
        var pending = Data()
        do {
            try LazyDirectoryWalker.walk(root: originalRoot, skipHidden: false) { entry in
                try Task.checkCancellation()
                if entry.isDirectory {
                    try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: entry.url.path(percentEncoded: false))
                    return .continue
                }
                let hash = mode == .immediate ? try StreamingHasher.sha256(of: entry.url).hex : "-"
                pending.append(contentsOf: "\(entry.fileSize)\t\(hash)\t\(entry.relativePath)\n".utf8)
                if pending.count >= 64 << 10 {
                    try out.write(contentsOf: pending)
                    pending.removeAll(keepingCapacity: true)
                }
                try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: entry.url.path(percentEncoded: false))
                files += 1
                bytes += entry.fileSize
                return .continue
            }
            try out.write(contentsOf: pending)
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: originalRoot.path(percentEncoded: false))
            try out.close()
            if fm.fileExists(atPath: manifest.path(percentEncoded: false)) {
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
    /// A manifest replaced meanwhile (the game re-imported over itself) is left alone: its lines are not these.
    public static func completeDeferredHashing(originalRoot: URL, manifest: URL) async throws {
        let before = identity(of: manifest)
        let temp = manifest.appendingPathExtension("rehash")
        _ = FileManager.default.createFile(atPath: temp.path(percentEncoded: false), contents: nil)
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
            guard before != nil, identity(of: manifest) == before else {
                try? FileManager.default.removeItem(at: temp)
                return
            }
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

    /// Which file a path names, and when it last changed: a replaced manifest is a different file.
    private static func identity(of url: URL) -> [String]? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)) else { return nil }
        return ["\(a[.systemFileNumber] ?? "")", "\((a[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0)", "\(a[.size] ?? "")"]
    }

    private static func treeSize(_ root: URL) -> Int64 {
        var total: Int64 = 0
        try? LazyDirectoryWalker.walk(root: root, skipHidden: false) { total += $0.fileSize; return .continue }
        return total
    }
}
