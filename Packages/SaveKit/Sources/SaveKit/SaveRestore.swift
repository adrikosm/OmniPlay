import Diagnostics
import Foundation
import GameCore

/// `file%d.rpgsave`, `Save%02d.rvdata2`: reads the index out of a slot file name and builds the next one.
public struct SlotPattern: Sendable, Hashable {
    public let format: String
    private let regex: String

    public init?(_ format: String) {
        guard format.contains("%") else { return nil }
        self.format = format
        let escaped = NSRegularExpression.escapedPattern(for: format)
        guard let range = escaped.range(of: #"%0?\d*d"#, options: .regularExpression) else { return nil }
        regex = "^" + escaped.replacingCharacters(in: range, with: #"(\d+)"#) + "$"
    }

    public func index(of fileName: String) -> Int? {
        guard let compiled = try? Regex(regex), let match = fileName.wholeMatch(of: compiled), match.output.count > 1,
              let digits = match.output[1].substring else { return nil }
        return Int(digits)
    }

    public func name(index: Int) -> String { String(format: format, index) }
}

public enum RestoreMode: Sendable, Hashable {
    /// Slots and persistent data become exactly what the snapshot holds.
    case replace
    /// Snapshot slots are added under the next free indices; persistent data is left alone.
    case stackIntoFreeSlots(slotPattern: String?)
}

public enum RestoreError: Error, Equatable { case noManifest, swapFailed(String) }

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
        try location.ensure()
        let backup = try await snapshot(location: location, identityHash: identityHash, reason: .beforeEdit)
        switch mode {
        case .replace:
            let staging = location.root.appending(path: ".restoring-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? fm.removeItem(at: staging) }
            for name in ["slots", "persistent"] {
                try await cloneTree(from: dir.appending(path: name), to: staging.appending(path: name))
            }
            try swap(staging: staging, into: location)
        case let .stackIntoFreeSlots(pattern):
            let slot = pattern.flatMap(SlotPattern.init)
            let existing = Set((try? fm.contentsOfDirectory(atPath: location.slots.path(percentEncoded: false))) ?? [])
            var next = (existing.compactMap { slot?.index(of: $0) }.max() ?? 0) + 1
            for file in (try? fm.contentsOfDirectory(at: dir.appending(path: "slots"), includingPropertiesForKeys: nil)) ?? []
                where !file.lastPathComponent.hasPrefix(".") {
                var name = file.lastPathComponent
                if existing.contains(name) {
                    guard let slot, slot.index(of: name) != nil else {
                        OPLog.log(.save, .default, "stack restore skipped \(name): already present and not a numbered slot")
                        continue
                    }
                    name = slot.name(index: next)
                    next += 1
                }
                try await APFSClone.clone(from: file, to: location.slots.appending(path: name))
            }
        }
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
