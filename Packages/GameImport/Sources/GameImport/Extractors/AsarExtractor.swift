import Diagnostics
import Foundation
import GameCore

/// Electron ASAR: a Pickle-framed JSON header followed by concatenated file bodies. The header is the only thing
/// held in memory (bounded); every body is streamed in 1 MiB slices. `unpacked` entries come from the
/// `<name>.asar.unpacked/` sibling. Every path goes through the same validator as archive entries.
public struct AsarExtractor: Sendable {
    public static let maxHeaderBytes = 64 << 20
    public static let chunk = 1 << 20
    public let limits: SafetyLimits

    public init(limits: SafetyLimits = .default) { self.limits = limits }

    /// Parsed header; `json` is Foundation's tree, so the value stays on the thread that read it.
    public struct Header {
        public let json: [String: Any]
        public let dataOffset: UInt64
    }

    /// Reads and parses the header without touching the bodies.
    public static func header(of url: URL) throws -> Header {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let prefix = try handle.read(upToCount: 16),
              prefix.count == 16 else { throw ImportFailure.unsupportedContainer(firstBytesHex: "asar: short header") }
        let words = prefix
            .withUnsafeBytes { raw in (0 ..< 4).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self).littleEndian } }
        guard words[0] == 4, words[3] <= words[2], Int(words[3]) <= maxHeaderBytes else {
            throw ImportFailure.unsupportedContainer(firstBytesHex: "asar: header \(words[3]) bytes is not plausible")
        }
        guard let jsonData = try handle.read(upToCount: Int(words[3])), jsonData.count == Int(words[3]),
              let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any], object["files"] is [String: Any]
        else { throw ImportFailure.unsupportedContainer(firstBytesHex: "asar: header is not a file tree") }
        return Header(json: object, dataOffset: UInt64(8) + UInt64(words[1]))
    }

    /// Unpacks `url` into `destination`; returns the same totals the archive extractor reports.
    public func extract(_ url: URL, to destination: URL, progress: (@Sendable (Int64, String) -> Void)? = nil) throws -> RunningTotals {
        let header = try Self.header(of: url)
        let unpackedRoot = url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".unpacked", directoryHint: .isDirectory)
        let sourceBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        let validator = EntryValidator(limits: limits)
        var totals = RunningTotals()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var entries: [(path: String, node: [String: Any])] = []
        Self.flatten(header.json["files"] as? [String: Any] ?? [:], prefix: "", into: &entries)
        for (path, node) in entries {
            try Task.checkCancellation()
            let isDirectory = node["files"] != nil
            let size = (node["size"] as? NSNumber).map { Int64(truncating: $0) }
            let decision = validator.validate(
                ArchiveEntryHeader(path: path, kind: isDirectory ? .directory : .file, declaredSize: size),
                running: &totals
            )
            switch decision {
            case let .reject(v): throw v
            case .skip: continue
            case let .extract(rel):
                let target = destination.appending(path: rel)
                if isDirectory {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                    continue
                }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let written: Int64
                if node["unpacked"] as? Bool == true {
                    written = try Self.stream(from: unpackedRoot.appending(path: path), offset: 0, length: size, to: target)
                } else {
                    guard let offsetText = node["offset"] as? String, let offset = UInt64(offsetText) else {
                        throw ImportFailure.unsupportedContainer(firstBytesHex: "asar: \(path) has no offset")
                    }
                    // Both numbers come from the archive; an overflowing sum would trap rather than fail the import.
                    let (start, overflow) = header.dataOffset.addingReportingOverflow(offset)
                    guard !overflow else { throw ImportFailure.unsupportedContainer(firstBytesHex: "asar: \(path) offset out of range") }
                    written = try Self.stream(from: url, offset: start, length: size, to: target)
                }
                totals.writtenBytes += written
                if let v = validator.checkWritten(totals, sourceBytes: sourceBytes) {
                    throw v
                }
                progress?(totals.writtenBytes, rel)
            }
        }
        return totals
    }

    static func flatten(_ files: [String: Any], prefix: String, into out: inout [(path: String, node: [String: Any])]) {
        for name in files.keys.sorted() {
            guard let node = files[name] as? [String: Any] else { continue }
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            out.append((path, node))
            if let children = node["files"] as? [String: Any] {
                flatten(children, prefix: path, into: &out)
            }
        }
    }

    /// Copies `length` bytes from `offset` of `source` into `target` in bounded slices.
    static func stream(from source: URL, offset: UInt64, length: Int64?, to target: URL) throws -> Int64 {
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        try reader.seek(toOffset: offset)
        _ = FileManager.default.createFile(atPath: target.path(percentEncoded: false), contents: nil)
        let writer = try FileHandle(forWritingTo: target)
        defer { try? writer.close() }
        var remaining = length ?? Int64.max
        var written: Int64 = 0
        while remaining > 0 {
            let want = Int(min(Int64(chunk), remaining))
            let piece = try autoreleasepool { try reader.read(upToCount: want) } ?? Data()
            if piece.isEmpty {
                break
            }
            try writer.write(contentsOf: piece)
            written += Int64(piece.count)
            remaining -= Int64(piece.count)
        }
        if let length, written != length {
            throw ExtractionError.entry(path: target.lastPathComponent, message: "asar body truncated")
        }
        return written
    }
}
