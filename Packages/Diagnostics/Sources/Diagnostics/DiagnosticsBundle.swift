import Foundation

/// Exports one session directory for the share sheet. Copies the directory into `tmp/` for now;
/// DIAG-001 replaces the copy with a zip once the libarchive writer exists.
public enum DiagnosticsBundle {
    public static func export(sessionDirectory: URL, fileManager: FileManager = .default) throws -> URL {
        let out = fileManager.temporaryDirectory
            .appending(path: "OmniPlay-diagnostics-\(sessionDirectory.lastPathComponent)", directoryHint: .isDirectory)
        try? fileManager.removeItem(at: out)
        try fileManager.copyItem(at: sessionDirectory, to: out)
        return out
    }
}
