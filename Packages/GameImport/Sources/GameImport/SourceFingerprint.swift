import CryptoKit
import Foundation
import GameCore

/// Identity of an import source for duplicate detection: a streamed SHA-256 for a file, and for a folder an
/// order-independent combination of per-entry hashes over `(relative path, size, first 4 KiB)` so no path list is
/// retained. The sample tells a same-size edit (a translated `Game.ini`) from the folder already imported without
/// reading every byte; modification dates would not do, since a Wi-Fi upload writes every file anew.
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
            var hasher = SHA256()
            hasher.update(data: Data("\(entry.relativePath.precomposedStringWithCanonicalMapping.lowercased())\u{0}\(entry.fileSize)".utf8))
            hasher.update(data: head(of: entry))
            let digest = hasher.finalize()
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

    /// The first 4 KiB of a regular file. Links are not followed and a FIFO never blocks the open; anything that
    /// cannot be read samples as empty, which leaves path and size to tell it apart.
    private static func head(of entry: RelativeEntry) -> Data {
        guard !entry.isSymbolicLink else { return Data() }
        let fd = open(entry.url.path(percentEncoded: false), O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return Data() }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &buffer, buffer.count)
        return count > 0 ? Data(buffer[..<count]) : Data()
    }
}
