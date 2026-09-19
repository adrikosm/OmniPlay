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

public struct PersistentStoreInfo: Sendable, Hashable, Identifiable {
    public var id: PersistentStoreKind { kind }
    public let kind: PersistentStoreKind
    public let directory: URL
    public let files: Int
    public let bytes: Int64
    public let modifiedAt: Date?
    public var isPresent: Bool { files > 0 }
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
            var files = 0
            var bytes: Int64 = 0
            var latest: Date?
            try? LazyDirectoryWalker.walk(root: dir) { entry in
                if !entry.isDirectory {
                    files += 1
                    bytes += entry.fileSize
                    if let date = try? entry.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                       latest.map({ date > $0 }) ?? true {
                        latest = date
                    }
                }
                return .continue
            }
            return PersistentStoreInfo(kind: kind, directory: dir, files: files, bytes: bytes, modifiedAt: latest)
        }
    }

    /// Empties one store after a snapshot; the game starts fresh next launch and the snapshot brings it back.
    public static func reset(_ store: PersistentStoreInfo, location: SaveLocation, identityHash: String) async throws {
        var files: [URL] = []
        try? LazyDirectoryWalker.walk(root: store.directory) { entry in
            if !entry.isDirectory {
                files.append(entry.url)
            }
            return .continue
        }
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
}
