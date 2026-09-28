import Diagnostics
import Foundation
import GameCore

/// `file%d.rpgsave`, `Save%02d.rvdata2`: reads the index out of a slot file name and builds the next one.
public struct SlotPattern: Sendable, Hashable {
    public let format: String
    private let prefix: String
    private let suffix: String
    private let width: Int

    public init?(_ format: String) {
        // A slot pattern is a filename with one decimal placeholder, never a C format program.
        guard !format.contains("/"), !format.contains("\\"),
              let match = format.wholeMatch(of: /([^%]*)%0?([0-9]*)d([^%]*)/),
              let width = match.2.isEmpty ? 0 : Int(match.2), width <= 19 else { return nil }
        self.format = format
        prefix = String(match.1)
        suffix = String(match.3)
        self.width = width
    }

    public func index(of fileName: String) -> Int? {
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(suffix), fileName.count > prefix.count + suffix.count else { return nil }
        let digits = fileName.dropFirst(prefix.count).dropLast(suffix.count)
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    public func name(index: Int) -> String {
        let digits = String(index)
        return prefix + String(repeating: "0", count: max(0, width - digits.count)) + digits + suffix
    }
}

public enum RestoreMode: Sendable, Hashable {
    /// Slots and persistent data become exactly what the snapshot holds.
    case replace
    /// Snapshot slots are added under the next free indices; persistent data is left alone.
    case stackIntoFreeSlots(slotPattern: String?)
}

public enum RestoreError: Error, Equatable { case noManifest, invalidSnapshot, noFreeSlot(String), swapFailed(String) }

public extension SaveVault {
    /// Newest snapshots to keep; a per-game override between 1 and 10, default 3.
    static func retention(from overrides: [String: String]) -> Int {
        min(10, max(1, overrides["snapshotRetention"].flatMap(Int.init) ?? 3))
    }

    /// Restores a snapshot directory. A `.beforeEdit` snapshot is taken first, files are staged as clones and swapped in,
    /// so a failure half-way leaves the live saves untouched.
    @discardableResult
    static func restore(
        snapshot dir: URL,
        into location: SaveLocation,
        identityHash: String,
        mode: RestoreMode
    ) async throws -> SaveSnapshot {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appending(path: "manifest.json").path(percentEncoded: false)) else { throw RestoreError.noManifest }
        _ = try validatedSnapshot(at: dir)
        try location.ensure()
        let backup = try await snapshot(location: location, identityHash: identityHash, reason: .beforeEdit)
        let staging = location.root.appending(path: ".restoring-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: staging) }
        let source: URL = switch mode {
        case .replace: dir
        case .stackIntoFreeSlots: location.root
        }
        for name in ["slots", "persistent"] {
            try await cloneTree(from: source.appending(path: name), to: staging.appending(path: name))
        }
        if case let .stackIntoFreeSlots(pattern) = mode {
            let stagedSlots = staging.appending(path: "slots")
            var occupied = try Set(fm.contentsOfDirectory(atPath: stagedSlots.path(percentEncoded: false)))
            let files = try fm.contentsOfDirectory(at: dir.appending(path: "slots"), includingPropertiesForKeys: nil)
                .filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            // Reserve original incoming names too, so a renamed collision cannot overwrite the next incoming file.
            let incoming = Set(files.map(\.lastPathComponent))
            for file in files {
                var name = file.lastPathComponent
                if occupied.contains(name) {
                    guard let free = SlotNaming.duplicateName(for: name, existing: occupied.union(incoming), pattern: pattern) else {
                        throw RestoreError.noFreeSlot(name)
                    }
                    name = free
                }
                try await APFSClone.clone(from: file, to: stagedSlots.appending(path: name))
                occupied.insert(name)
            }
        }
        try swap(staging: staging, into: location)
        OPLog.log(.save, .info, "restored \(dir.lastPathComponent) (\(mode))")
        return backup
    }

    private static func cloneTree(from source: URL, to target: URL) async throws {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else { return }
        var files: [RelativeEntry] = []
        try LazyDirectoryWalker.walk(root: source) { entry in
            if !entry.isDirectory {
                files.append(entry)
            }
            return .continue
        }
        for file in files {
            try await APFSClone.clone(from: file.url, to: target.appending(path: file.relativePath))
        }
    }

    /// Renames live directories aside, moves staged ones in, then deletes the old ones; any failure moves them back.
    private static func swap(staging: URL, into location: SaveLocation) throws {
        let fm = FileManager.default
        var moved: [(aside: URL, live: URL)] = []
        do {
            for name in ["slots", "persistent"] {
                let live = location.root.appending(path: name, directoryHint: .isDirectory)
                let aside = location.root.appending(path: ".old-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
                if fm.fileExists(atPath: live.path(percentEncoded: false)) {
                    try fm.moveItem(at: live, to: aside)
                }
                moved.append((aside, live))
                try fm.moveItem(at: staging.appending(path: name), to: live)
            }
        } catch {
            for (aside, live) in moved.reversed() {
                try? fm.removeItem(at: live)
                if fm.fileExists(atPath: aside.path(percentEncoded: false)) {
                    try? fm.moveItem(at: aside, to: live)
                }
            }
            throw RestoreError.swapFailed(String(describing: error))
        }
        for (aside, _) in moved {
            try? fm.removeItem(at: aside)
        }
    }
}

/// Saves that outlive their game: moved aside on deletion and offered back when the same title returns.
public enum RescuedSaves {
    public struct Record: Codable, Sendable, Hashable {
        public let titleHash: String
        public let title: String
        public let rescuedAt: Date
    }

    /// Moves `Saves/` to `RescuedSaves/<titleHash>-<stamp>/`; nil when there was nothing to keep.
    @discardableResult
    public static func rescue(location: SaveLocation, titleHash: String, title: String, paths: AppPaths) throws -> URL? {
        guard SaveVault.hasContent(location) else { return nil }
        let stamp = Date.now.formatted(.iso8601.year().month().day().timeZone(separator: .omitted).time(includingFractionalSeconds: false))
            .replacingOccurrences(
                of: ":",
                with: ""
            )
        let target = paths.rescuedSaves().appending(path: "\(titleHash.prefix(24))-\(stamp)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: location.root, to: target)
        try AtomicFileWriter.write(
            JSONEncoder().encode(Record(titleHash: titleHash, title: title, rescuedAt: .now)),
            to: target.appending(path: "rescue.json")
        )
        OPLog.log(.save, .info, "rescued saves of \(title) → \(target.lastPathComponent)")
        return target
    }

    /// Rescues for a title fingerprint, newest first.
    public static func find(titleHash: String, paths: AppPaths) -> [(directory: URL, record: Record)] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: paths.rescuedSaves(), includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appending(path: "rescue.json")),
                  let record = try? JSONDecoder().decode(Record.self, from: data), record.titleHash == titleHash else { return nil }
            return (dir.standardizedFileURL, record)
        }.sorted { $0.record.rescuedAt > $1.record.rescuedAt }
    }

    /// Puts a rescue back as the game's `Saves/`. Only for a game that has no saves yet.
    public static func restore(from dir: URL, into location: SaveLocation) throws {
        guard !SaveVault.hasContent(location) else { return }
        try? FileManager.default.removeItem(at: location.root)
        try FileManager.default.createDirectory(at: location.root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: dir, to: location.root)
        try? FileManager.default.removeItem(at: location.root.appending(path: "rescue.json"))
        OPLog.log(.save, .info, "restored rescued saves from \(dir.lastPathComponent)")
    }
}
