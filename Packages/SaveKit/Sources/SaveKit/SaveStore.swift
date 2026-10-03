import CryptoKit
import Diagnostics
import Foundation
import GameCore

/// The host-owned save directories of one game, all under `Saves/`.
public struct SaveLocation: Sendable, Hashable {
    public let root: URL
    public var slots: URL { root.appending(path: "slots", directoryHint: .isDirectory) }
    public var backups: URL { root.appending(path: "backups", directoryHint: .isDirectory) }
    public var persistent: URL { root.appending(path: "persistent", directoryHint: .isDirectory) }
    public var provenance: URL { root.appending(path: "provenance.json") }

    public init(savesRoot: URL) { root = savesRoot }

    public static func forGame(_ id: GameID, paths: AppPaths) -> SaveLocation { SaveLocation(savesRoot: paths.tier(.saves, for: id)) }

    public func ensure() throws {
        for dir in [slots, backups, persistent] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

/// Temp file + fsync + rename, so a crash mid-write leaves the previous save intact.
public enum AtomicFileWriter {
    public static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).part-\(UUID().uuidString)")
        _ = fm.createFile(atPath: temp.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: temp)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            if fm.fileExists(atPath: url.path(percentEncoded: false)) {
                _ = try fm.replaceItemAt(url, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: url)
            }
        } catch {
            try? handle.close()
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// Removes `.part-*` leftovers of interrupted writes.
    @discardableResult
    public static func sweepStale(in dir: URL) -> Int {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return 0 }
        var n = 0
        for item in items
            where item.lastPathComponent.hasPrefix(".") && item.lastPathComponent.contains(".part-") {
            if (try? FileManager.default.removeItem(at: item)) != nil {
                n += 1
            }
        }
        return n
    }
}

/// Keys come from game scripts; only this shape reaches a file name.
public enum SaveKey {
    /// `^[A-Za-z0-9_.:-]{1,128}$`, written out so the check stays Sendable-safe.
    public static func validate(_ key: String) -> String? {
        guard (1 ... 128).contains(key.utf8.count),
              key.utf8
              .allSatisfy({ (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains($0) || (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains($0)
                      || (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0) || "_.:-".utf8.contains($0) })
        else { return nil }
        return key.replacingOccurrences(of: ":", with: "_")
    }

    /// Arbitrary web-storage keys ("RPG File1") become `ls.<base64url>` file stems and back.
    public static func encodeWebStorage(_ key: String) -> String {
        "ls." + Data(key.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(
                of: "=",
                with: ""
            )
    }

    public static func decodeWebStorage(_ stem: String) -> String? {
        guard stem.hasPrefix("ls.") else { return nil }
        var b64 = String(stem.dropFirst(3)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        return Data(base64Encoded: b64).flatMap { String(data: $0, encoding: .utf8) }
    }
}

/// Typed save files under one directory (`Saves/slots` by default, or a persistent store folder).
public struct SaveFileStore: Sendable {
    public let location: SaveLocation
    public let directory: URL
    public let fileExtension: String

    public init(location: SaveLocation, fileExtension: String, directory: URL? = nil) {
        self.location = location
        self.directory = directory ?? location.slots
        self.fileExtension = fileExtension
    }

    public enum Failure: Error, Equatable { case invalidKey(String), tooLarge(Int) }
    public static let maxBytes = 16 << 20

    public func url(for key: String) throws -> URL {
        guard let safe = SaveKey.validate(key) else { throw Failure.invalidKey(key) }
        return directory.appending(path: "\(safe).\(fileExtension)")
    }

    public func write(_ data: Data, key: String) throws {
        guard data.count <= Self.maxBytes else { throw Failure.tooLarge(data.count) }
        try location.ensure()
        try AtomicFileWriter.write(data, to: url(for: key))
    }

    public func read(key: String) throws -> Data? {
        let url = try url(for: key)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return try SmallFileGuard.read(url, maxBytes: Self.maxBytes)
    }

    public func remove(key: String) throws {
        do {
            try FileManager.default.removeItem(at: url(for: key))
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return
        }
    }

    /// Every stored key with its file size, sorted.
    public func keys() throws -> [(key: String, bytes: Int64)] {
        let items = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        return try items.filter { $0.pathExtension == fileExtension && !$0.lastPathComponent.hasPrefix(".") }
            .map { try ($0.deletingPathExtension().lastPathComponent, Int64($0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)) }
            .sorted { $0.0 < $1.0 }
    }
}

/// Provenance written once per game beside the saves.
public struct SaveProvenanceRecord: Codable, Sendable, Hashable {
    public let gameID: GameID
    public let titleHash: String
    public let engine: EngineFamily
    public let createdBy: String
    public let createdAt: Date
}

/// Snapshots: clone slots and persistent data into `backups/<timestamp>/` with a manifest. Cheap on APFS.
public enum SaveVault {
    public static func writeProvenance(game: GameID, titleHash: String, engine: EngineFamily, location: SaveLocation) throws {
        guard !FileManager.default.fileExists(atPath: location.provenance.path(percentEncoded: false)) else { return }
        let record = SaveProvenanceRecord(gameID: game, titleHash: titleHash, engine: engine, createdBy: "OmniPlay", createdAt: .now)
        try AtomicFileWriter.write(JSONEncoder().encode(record), to: location.provenance)
    }

    /// True when there is anything worth snapshotting.
    public static func hasContent(_ location: SaveLocation) -> Bool {
        [location.slots, location.persistent]
            .contains { directory in
                do {
                    return try !FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).isEmpty
                } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                    return false
                } catch {
                    return true // Unreadable saves must still be rescued before deleting the game.
                }
            }
    }

    public static func snapshot(location: SaveLocation, identityHash: String, reason: SaveProvenance.Origin) async throws -> SaveSnapshot {
        try location.ensure()
        let id = UUID()
        let stamp = Self.stamp(fractional: true) + "-" + id.uuidString.prefix(4)
        let target = location.backups.appending(path: stamp, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        var complete = false
        defer {
            if !complete {
                try? FileManager.default.removeItem(at: target)
            }
        }
        for (source, name) in [(location.slots, "slots"), (location.persistent, "persistent")]
            where FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) {
            try await cloneTree(from: source, to: target.appending(path: name))
        }
        // Hashed from the clones, exactly as `validatedSnapshot` re-reads them.
        let entries = try SaveExportManifest.entries(for: SaveLocation(savesRoot: target))
        let snapshot = SaveSnapshot(
            id: id,
            provenance: SaveProvenance(gameIdentityHash: identityHash, origin: reason),
            entries: entries,
            checksum: checksum(entries)
        )
        try AtomicFileWriter.write(JSONEncoder().encode(snapshot), to: target.appending(path: "manifest.json"))
        complete = true
        OPLog.log(.save, .info, "snapshot \(stamp): \(entries.count) files (\(reason.rawValue))")
        return snapshot
    }

    /// SHA-256 over the entry hashes in path order, hex.
    static func checksum(_ entries: [SaveEntry]) -> String { SHA256.hash(data: Data(entries.map(\.sha256).joined().utf8)).hex }

    /// `20261003T142501.123Z`-style, colons dropped so it is a valid file name.
    static func stamp(fractional: Bool) -> String {
        Date.now.formatted(.iso8601.year().month().day().timeZone(separator: .omitted).time(includingFractionalSeconds: fractional))
            .replacingOccurrences(of: ":", with: "")
    }

    /// A damaged or incomplete backup must never become an instruction to delete live saves.
    static func validatedSnapshot(at directory: URL) throws -> SaveSnapshot {
        let manifest = try JSONDecoder().decode(SaveSnapshot.self, from: SmallFileGuard.read(directory.appending(path: "manifest.json")))
        let entries = try SaveExportManifest.entries(for: SaveLocation(savesRoot: directory))
        guard entries == manifest.entries.sorted(by: { $0.relativePath < $1.relativePath }),
              checksum(entries) == manifest.checksum else {
            throw RestoreError.invalidSnapshot
        }
        return manifest
    }

    /// Manifests of every snapshot, newest first.
    public static func snapshots(location: SaveLocation) -> [(directory: URL, manifest: SaveSnapshot)] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: location.backups, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir in
            guard let data = try? SmallFileGuard.read(dir.appending(path: "manifest.json")),
                  let m = try? JSONDecoder().decode(SaveSnapshot.self, from: data) else { return nil }
            return (dir, m)
        }.sorted { $0.manifest.timestamp > $1.manifest.timestamp }
    }

    /// Keeps the newest `keep` snapshots of each automatic origin, so launches never push out the snapshot a delete or
    /// edit promised; manual ones and pre-mod/pre-cheat backups stay.
    @discardableResult
    public static func prune(location: SaveLocation, keep: Int) -> Int {
        let all = snapshots(location: location)
        var removed = 0
        for origin: SaveProvenance.Origin in [.beforeLaunch, .beforeEdit, .crash] {
            let old = all.filter { $0.manifest.provenance.origin == origin }.dropFirst(keep)
            for snapshot in old where (try? FileManager.default.removeItem(at: snapshot.directory)) != nil {
                removed += 1
            }
        }
        return removed
    }
}
