import CryptoKit
import Foundation
import GameCore

/// Identity of an import source for duplicate detection: a streamed SHA-256 for a file, and for a folder an
/// order-independent combination of per-entry hashes over `(relative path, size)` so no path list is retained.
/// ponytail: archives are hashed in a separate streaming pass (one extra read); tee into libarchive's read
/// callbacks if hashing shows up in import profiles.
public enum SourceFingerprint {
    public static func compute(_ url: URL) throws -> String {
        if try (url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return try folder(url)
        }
        return try StreamingHasher.sha256(of: url).hex
    }

    static func folder(_ root: URL) throws -> String {
        var lanes = [UInt64](repeating: 0, count: 4)
        var count: UInt64 = 0
        try LazyDirectoryWalker.walk(root: root) { entry in
            guard !entry.isDirectory else { return .continue }
            let digest = SHA256
                .hash(data: Data("\(entry.relativePath.precomposedStringWithCanonicalMapping.lowercased())\u{0}\(entry.fileSize)".utf8))
            digest.withUnsafeBytes { raw in
                for i in 0 ..< 4 {
                    lanes[i] &+= raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)
                }
            }
            count += 1
            return .continue
        }
        var final = Data()
        for lane in lanes + [count] {
            withUnsafeBytes(of: lane.littleEndian) { final.append(contentsOf: $0) }
        }
        return "folder-" + SHA256.hash(data: final).hex
    }
}
