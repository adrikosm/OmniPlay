import Foundation
import OSLog

/// Buffered, rotating writer for one session's `host.log`. Lines are appended to a 64 KiB buffer
/// that flushes when full or one second after the first pending line. At `maxFileBytes` the file
/// rotates to `host.1.log`, `host.2.log`; older files are deleted, so a session never holds more
/// than three files. A write failure disables the sink for the session (OSLog keeps working).
public actor FileLogSink {
    public static let defaultMaxFileBytes = 8 << 20
    public static let maxFiles = 3
    static let bufferLimit = 64 << 10

    public let directory: URL
    let maxFileBytes: Int
    private var handle: FileHandle?
    private var buffer = Data()
    private var written = 0
    private var disabled = false
    private var flushTask: Task<Void, Never>?

    public init(directory: URL, maxFileBytes: Int = FileLogSink.defaultMaxFileBytes) {
        self.directory = directory
        self.maxFileBytes = maxFileBytes
    }

    public nonisolated var currentFile: URL { directory.appending(path: "host.log") }

    public func append(_ line: String) {
        guard !disabled else { return }
        // Rotate on line boundaries so no file exceeds the cap and no line is split.
        if written + buffer.count + line.utf8.count + 1 > maxFileBytes, written + buffer.count > 0 {
            flush()
            do { try rotate() } catch { disable(error) }
        }
        buffer.append(contentsOf: line.utf8)
        buffer.append(UInt8(ascii: "\n"))
        if buffer.count >= Self.bufferLimit {
            flush()
        } else if flushTask == nil {
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                await self?.flush()
            }
        }
    }

    public func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard !buffer.isEmpty, !disabled else { return }
        do {
            if handle == nil {
                try open()
            }
            try handle?.write(contentsOf: buffer)
            written += buffer.count
            buffer.removeAll(keepingCapacity: true)
        } catch {
            disable(error)
        }
    }

    private func disable(_ error: Error) {
        disabled = true
        buffer.removeAll()
        OPLog.logger(.crash).error("file log sink disabled: \(error.localizedDescription, privacy: .public)")
    }

    public func close() {
        flush()
        try? handle?.close()
        handle = nil
    }

    private func open() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = currentFile
        if !FileManager.default.fileExists(atPath: url.path()) {
            try Data().write(to: url)
        }
        let h = try FileHandle(forWritingTo: url)
        written = try Int(h.seekToEnd())
        handle = h
    }

    private func rotate() throws {
        try handle?.close()
        handle = nil
        let fm = FileManager.default
        for i in stride(from: Self.maxFiles - 1, through: 1, by: -1) {
            let from = i == 1 ? currentFile : directory.appending(path: "host.\(i - 1).log")
            let to = directory.appending(path: "host.\(i).log")
            try? fm.removeItem(at: to)
            if fm.fileExists(atPath: from.path()) {
                try fm.moveItem(at: from, to: to)
            }
        }
        written = 0
    }
}
