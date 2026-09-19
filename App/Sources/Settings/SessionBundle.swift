import Diagnostics
import Foundation
import GameImport

/// One session directory (host.log, web-console.log, memory.jsonl, termination.json, detection.json when
/// present) zipped for the share sheet. Missing files are simply absent; a README lists what was included.
enum SessionBundle {
    static func export(sessionDirectory: URL) async throws -> URL {
        if let uuid = UUID(uuidString: sessionDirectory.lastPathComponent), let sink = OPLog.sink(for: SessionID(rawValue: uuid)) {
            await sink.flush()
        }
        let out = FileManager.default.temporaryDirectory.appending(path: "OmniPlay-session-\(sessionDirectory.lastPathComponent).zip")
        try? FileManager.default.removeItem(at: out)
        let present = ((try? FileManager.default.contentsOfDirectory(atPath: sessionDirectory.path(percentEncoded: false))) ?? []).sorted()
        let note = """
        OmniPlay session bundle
        session: \(sessionDirectory.lastPathComponent)
        exported: \(Date.now.formatted(.iso8601))
        files: \(present.joined(separator: ", "))

        """
        try ArchiveWriter().zip(
            directory: sessionDirectory,
            to: out,
            prefix: sessionDirectory.lastPathComponent,
            extras: [("README.txt", Data(note.utf8))]
        )
        // Exported sessions are pinned by log retention so the bundle's source outlives the usual rotation.
        try? Data().write(to: sessionDirectory.appending(path: ".exported"))
        return out
    }
}
