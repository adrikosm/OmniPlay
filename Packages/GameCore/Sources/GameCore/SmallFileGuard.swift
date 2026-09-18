import Foundation

public struct FileTooLargeError: Error, Equatable, Sendable {
    public let url: URL
    public let size: Int
    public let limit: Int
}

/// The only sanctioned whole-file read. Anything that can be large is streamed (see `IO/`).
public enum SmallFileGuard {
    public static let defaultMaxBytes = 8 << 20

    public static func read(_ url: URL, maxBytes: Int = defaultMaxBytes) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maxBytes else { throw FileTooLargeError(url: url, size: size, limit: maxBytes) }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }
}
