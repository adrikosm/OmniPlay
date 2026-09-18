import Foundation

/// Read-only view of an imported game tree used by detection signatures. Paths are relative,
/// forward-slash, NFC — exactly as stored in the case-insensitive index (design authority §13.4).
/// Detection never touches the filesystem directly; the importer supplies a probe.
public protocol GameTreeProbe: Sendable {
    var paths: [String] { get }
    /// The first `maxBytes` of a file, or nil if it does not exist.
    func readPrefix(of relativePath: String, maxBytes: Int) throws -> Data?
}

public extension GameTreeProbe {
    func contains(_ relativePath: String) -> Bool {
        paths.contains { $0.caseInsensitiveCompare(relativePath) == .orderedSame }
    }

    func paths(withExtension ext: String) -> [String] {
        paths.filter { ($0 as NSString).pathExtension.caseInsensitiveCompare(ext) == .orderedSame }
    }
}
