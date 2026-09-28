import Foundation

public struct RelativeEntry: Sendable, Hashable {
    public let relativePath: String
    public let isDirectory: Bool
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
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]
        var options: FileManager.DirectoryEnumerationOptions = []
        if skipHidden {
            options.insert(.skipsHiddenFiles)
        }
        var failure: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: options,
            errorHandler: { _, error in failure = error; return false }
        ) else { throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: root.path]) }
        let rootPath = root.standardizedFileURL.path(percentEncoded: false)
        while let url = enumerator.nextObject() as? URL {
            // One pool per entry keeps the autoreleased NSURL / resource dictionaries from accumulating.
            let directive: WalkDirective? = try autoreleasepool {
                let values = try url.resourceValues(forKeys: Set(keys))
                let isDir = (values.isDirectory ?? false) && !(values.isSymbolicLink ?? false)
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
                let entry = RelativeEntry(relativePath: rel, isDirectory: isDir, fileSize: Int64(values.fileSize ?? 0), url: url)
                let d = try onEntry(entry)
                if case .skipDescendants = d, isDir {
                    enumerator.skipDescendants()
                }
                return d
            }
            if case .stop = directive {
                return
            }
        }
        if let failure {
            throw failure
        }
    }
}
