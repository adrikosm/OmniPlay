import Diagnostics
import Foundation
import GameCore

/// Engine-persistent data that lives beside the slots and has its own backup and reset semantics.
public enum PersistentStoreKind: String, Sendable, Codable, CaseIterable, Hashable {
    case webLocalStorage, webIndexedDB, mvGlobalConfig, renpyPersistent, easyrpgConfig, scummvmConfig, godotUserSettings

    /// Folder under `Saves/persistent/`. MV's config and global live inside the web storage mirror.
    public var directoryName: String { self == .mvGlobalConfig ? PersistentStoreKind.webLocalStorage.rawValue : rawValue }

    public var title: String {
        switch self {
        case .webLocalStorage: "Web storage"
        case .webIndexedDB: "Engine database"
        case .mvGlobalConfig: "RPG Maker settings and global data"
        case .renpyPersistent: "Ren'Py persistent data"
        case .easyrpgConfig: "EasyRPG settings"
        case .scummvmConfig: "ScummVM settings"
        case .godotUserSettings: "Godot user settings"
        }
    }
}

public extension PersistentStoreKind {
    /// Where the engine keeps this store, relative to `Saves/`. Most live in `persistent/<folder>/`; Ren'Py writes its
    /// `persistent` file beside its slots (and a copy for Ren'Py Sync under `sync/`).
    func relativePaths(in location: SaveLocation) -> [String] {
        switch self {
        case .renpyPersistent:
            return ["slots/persistent", "slots/sync/persistent"]
                .filter { FileManager.default.fileExists(atPath: location.root.appending(path: $0).path(percentEncoded: false)) }
        default:
            let folder = location.persistent.appending(path: directoryName, directoryHint: .isDirectory)
            return ((try? LazyDirectoryWalker.files(under: folder)) ?? []).map { "persistent/\(directoryName)/\($0.relativePath)" }
        }
    }

    /// Whether a path relative to `Saves/` (or to a snapshot) belongs to this store.
    func owns(_ relativePath: String) -> Bool {
        switch self {
        case .renpyPersistent: relativePath == "slots/persistent" || relativePath == "slots/sync/persistent"
        default: relativePath.hasPrefix("persistent/\(directoryName)/")
        }
    }
}

public struct PersistentStoreInfo: Sendable, Hashable, Identifiable {
    public var id: PersistentStoreKind { kind }
    public let kind: PersistentStoreKind
    public let directory: URL
    /// The store's files, relative to `Saves/`.
    public let paths: [String]
    public let files: Int
    public let bytes: Int64
    public let modifiedAt: Date?
    public var isPresent: Bool { files > 0 }
    /// Reset keeps the save list, so a store holding only that has nothing to reset.
    public var resettablePaths: [String] { paths.filter { !SaveSlots.isSaveList(($0 as NSString).lastPathComponent) } }
}

/// What persistent stores a game has: the kinds its engine uses, plus anything actually on disk.
public enum PersistentStoreRegistry {
    public static func stores(location: SaveLocation, kinds: [PersistentStoreKind]) -> [PersistentStoreInfo] {
        var wanted = kinds
        let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: location.persistent.path(percentEncoded: false))) ?? []
        for name in onDisk {
            if let kind = PersistentStoreKind(rawValue: name), !wanted.contains(kind) {
                wanted.append(kind)
            }
        }
        var seenDirectories = Set<String>()
        return wanted.compactMap { kind in
            guard seenDirectories.insert(kind.directoryName).inserted else { return nil }
            let dir = location.persistent.appending(path: kind.directoryName, directoryHint: .isDirectory)
            let paths = kind.relativePaths(in: location)
            var bytes: Int64 = 0
            var latest: Date?
            for path in paths {
                let values = try? location.root.appending(path: path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                bytes += Int64(values?.fileSize ?? 0)
                if let date = values?.contentModificationDate, latest.map({ date > $0 }) ?? true {
                    latest = date
                }
            }
            return PersistentStoreInfo(kind: kind, directory: dir, paths: paths, files: paths.count, bytes: bytes, modifiedAt: latest)
        }
    }

    /// Empties one store after a snapshot; the game starts fresh next launch and the snapshot brings it back. The save
    /// list stays: without it every slot drops off the game's Load screen.
    public static func reset(_ store: PersistentStoreInfo, location: SaveLocation, identityHash: String) async throws {
        let files = store.resettablePaths.map { location.root.appending(path: $0) }
        guard !files.isEmpty else { return }
        let targets = files
        let txn = SafePersistTransaction(location: location, identityHash: identityHash)
        try await txn.run(targets: targets, reason: .beforeEdit) { staging in
            for file in targets {
                try? FileManager.default.removeItem(at: staging.url(for: file))
            }
        }
        OPLog.log(.save, .info, "reset \(store.kind.rawValue): \(files.count) files")
    }

    /// Puts one store back as it was in a snapshot, leaving slots and other stores alone: files the snapshot holds are
    /// copied in, files it does not hold are removed. Snapshot first, staged, swapped; a failure changes nothing.
    public static func restore(
        _ store: PersistentStoreInfo,
        from snapshot: URL,
        location: SaveLocation,
        identityHash: String
    ) async throws {
        let saved = try SaveVault.validatedSnapshot(at: snapshot).files.filter(store.kind.owns)
        let paths = Array(Set(saved + store.paths))
        guard !paths.isEmpty else { return }
        let targets = paths.map { location.root.appending(path: $0) }
        let savedSet = Set(saved)
        try await SafePersistTransaction(location: location, identityHash: identityHash)
            .run(targets: targets, reason: .beforeEdit) { staging in
                for (path, target) in zip(paths, targets) {
                    let staged = staging.url(for: target)
                    try? FileManager.default.removeItem(at: staged)
                    if savedSet.contains(path) {
                        try FileManager.default.copyItem(at: snapshot.appending(path: path), to: staged)
                    }
                }
            }
        OPLog.log(.save, .info, "restored \(store.kind.rawValue) from \(snapshot.lastPathComponent): \(saved.count) files")
    }
}
