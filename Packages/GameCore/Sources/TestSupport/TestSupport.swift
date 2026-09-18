import Foundation
import GameCore

/// Locates the repository's fixture folders from any package test, by walking up from this file.
public enum Fixtures {
    public static let repositoryRoot: URL = {
        var url = URL(filePath: #filePath)
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appending(path: "project.yml").path()) {
            url = url.deletingLastPathComponent()
        }
        return url
    }()

    public static func url(_ name: String) -> URL { repositoryRoot.appending(path: "Fixtures/synthetic/\(name)") }

    /// A real sample project placed locally under `Fixtures/private/`, or nil when absent (tests then skip).
    public static func privateURL(_ name: String) -> URL? {
        let url = repositoryRoot.appending(path: "Fixtures/private/\(name)")
        return FileManager.default.fileExists(atPath: url.path()) ? url : nil
    }

    public static func hasPrivate(_ name: String) -> Bool { privateURL(name) != nil }
}

/// A throwaway directory tree removed when the value is deinitialised.
public final class TemporaryGameRoot: Sendable {
    public let url: URL

    public init(name: String = "game") throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "omniplay-test-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Writes `contents` at `relativePath`, creating intermediate directories.
    @discardableResult
    public func file(_ relativePath: String, _ contents: Data = Data()) throws -> URL {
        let target = url.appending(path: relativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: target)
        return target
    }

    /// A sparse file of `bytes` length (reads as zeros, occupies no space until written).
    public func sparseFile(_ relativePath: String, bytes: UInt64) throws -> URL {
        let target = try file(relativePath)
        let h = try FileHandle(forWritingTo: target)
        try h.truncate(atOffset: bytes)
        try h.close()
        return target
    }

    public func remove() { try? FileManager.default.removeItem(at: url) }

    deinit { try? FileManager.default.removeItem(at: url) }
}

public enum MemoryAssert {
    /// `phys_footprint` growth across `work`, in bytes (negative when memory was released).
    public static func footprintGrowth(during work: () async throws -> Void) async throws -> Int64 {
        let before = Int64(ProcessFootprint.current ?? 0)
        try await work()
        return Int64(ProcessFootprint.current ?? 0) - before
    }
}
