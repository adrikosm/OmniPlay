import Diagnostics
import Foundation
import Testing

@Suite("Diagnostics")
struct DiagnosticsTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "diag-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test("Every category maps to a logger and the roadmap set is complete")
    func categories() {
        #expect(LogCategory.allCases.count == 18)
        #expect(LogCategory.allCases.contains(.ui))
        for c in LogCategory.allCases {
            _ = OPLog.logger(c)
        }
    }

    @Test("Session lines reach host.log with level and category")
    func sessionLines() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = SessionID()
        let sink = OPLog.beginSession(session, directory: dir)
        OPLog.log(.importer, .info, "hello import", session: session)
        OPLog.log(.web, .error, "boom", session: session)
        try await Task.sleep(for: .milliseconds(50))
        await sink.flush()
        let text = try String(contentsOf: sink.currentFile, encoding: .utf8)
        #expect(text.contains("\tinfo\timporter\thello import\n"))
        #expect(text.contains("\terror\tweb\tboom\n"))
        await OPLog.endSession(session)
        #expect(OPLog.sink(for: session) == nil)
    }

    @Test("Rotation caps a session at three files of the configured size")
    func rotation() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = FileLogSink(directory: dir, maxFileBytes: 4096)
        let line = String(repeating: "x", count: 99) // 100 bytes with newline
        for _ in 0 ..< 400 {
            await sink.append(line)
        } // 40 KiB, ~10 rotations
        await sink.close()
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path()).sorted()
        #expect(files == ["host.1.log", "host.2.log", "host.log"])
        for f in files {
            let size = try dir.appending(path: f).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            #expect(size <= 4096 + 100)
        }
    }

    @Test("Concurrent writers produce intact lines")
    func concurrentWrites() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = FileLogSink(directory: dir)
        await withTaskGroup(of: Void.self) { group in
            for t in 0 ..< 10 {
                group.addTask { for i in 0 ..< 200 {
                    await sink.append("task\(t) line\(i)")
                } }
            }
        }
        await sink.close()
        let lines = try String(contentsOf: sink.currentFile, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2000)
        #expect(lines.allSatisfy { $0.hasPrefix("task") && $0.contains(" line") })
    }

    @Test("Memory samples are populated and the recorder caps lines")
    func memory() async throws {
        let s = MemoryProbe.sample(label: "test")
        #expect((s.footprintBytes ?? 0) > 0)
        #expect((s.residentBytes ?? 0) > 0)
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = MemoryRecorder(fileURL: dir.appending(path: "memory.jsonl"))
        #expect(await rec.record(s))
        #expect(await rec.record(s) == false) // rate limited: same second
        #expect(await rec.record(s, force: true))
        await rec.close()
        let lines = try String(contentsOf: rec.fileURL, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].contains("\"label\":\"test\""))
    }

    @Test("Diagnostics bundle export copies the session directory")
    func export() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "x".write(to: dir.appending(path: "host.log"), atomically: true, encoding: .utf8)
        let out = try DiagnosticsBundle.export(sessionDirectory: dir)
        defer { try? FileManager.default.removeItem(at: out) }
        #expect(FileManager.default.fileExists(atPath: out.appending(path: "host.log").path()))
    }
}
