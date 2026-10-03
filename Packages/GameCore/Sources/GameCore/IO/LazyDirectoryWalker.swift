import Foundation

public struct RelativeEntry: Sendable, Hashable {
    public let relativePath: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let fileSize: Int64
    public let url: URL
}

public enum WalkDirective: Sendable {
    case `continue`
    /// Do not descend into this directory.
    case skipDescendants
    case stop
}

/// Yields one entry at a time from `FileManager.enumerator`; never builds an array of the tree.
/// Symbolic links are reported but never followed. Paths are relative, `/`-separated.
public enum LazyDirectoryWalker {
    public static func walk(root: URL, skipHidden: Bool = true, onEntry: (RelativeEntry) throws -> WalkDirective) throws {
        let cursor = try Cursor(root: root, skipHidden: skipHidden)
        while true {
            // One pool per entry keeps the autoreleased NSURL / resource dictionaries from accumulating.
            let directive: WalkDirective? = try autoreleasepool {
                guard let entry = try cursor.next() else { return nil }
                let d = try onEntry(entry)
                if case .skipDescendants = d, entry.isDirectory {
                    cursor.skipDescendants()
                }
                return d
            }
            guard let directive else { return }
            if case .stop = directive {
                return
            }
        }
    }

    /// The same walk pulled one entry at a time, for callers that await between entries: one enumerator for the whole
    /// tree, so slicing never re-walks from the root.
    public final class Cursor {
        private let enumerator: FileManager.DirectoryEnumerator
        private let failure = WalkFailure()
        private let rootPath: String
        private static let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]

        public init(root: URL, skipHidden: Bool = true) throws {
            let failure = failure
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: Self.keys, options: skipHidden ? [.skipsHiddenFiles] : [],
                errorHandler: { _, error in failure.error = error; return false }
            ) else { throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: root.path]) }
            self.enumerator = enumerator
            rootPath = root.standardizedFileURL.path(percentEncoded: false)
        }

        /// The next entry, or nil at the end; throws the enumerator's error once the walk ends on one.
        public func next() throws -> RelativeEntry? {
            guard let url = enumerator.nextObject() as? URL else {
                if let error = failure.error {
                    throw error
                }
                return nil
            }
            let values = try url.resourceValues(forKeys: Set(Self.keys))
            let isLink = values.isSymbolicLink ?? false
            let isDir = (values.isDirectory ?? false) && !isLink
            var rel = url.standardizedFileURL.path(percentEncoded: false)
            if rel.hasPrefix(rootPath) {
                rel.removeFirst(rootPath.count)
            }
            while rel.hasPrefix("/") {
                rel.removeFirst()
            }
            if rel.hasSuffix("/") {
                rel.removeLast()
            }
            return RelativeEntry(
                relativePath: rel,
                isDirectory: isDir,
                isSymbolicLink: isLink,
                fileSize: Int64(values.fileSize ?? 0),
                url: url
            )
        }

        public func skipDescendants() { enumerator.skipDescendants() }
    }
}

/// Where the enumerator's error handler leaves its error for `Cursor.next()`.
private final class WalkFailure { var error: Error? }
