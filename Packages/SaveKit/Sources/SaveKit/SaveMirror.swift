import Foundation
import GameCore

/// A copy of one game's `slots/` and `persistent/` in a folder the Files app shows (`Documents/Titles/Saves/<Title>/`).
/// The real saves never leave the transaction: the mirror is rewritten from them, and files the player adds or changes
/// in it are found by comparing it with its manifest (`.omniplay`), then imported through the normal save import.
public struct SaveMirror: Sendable {
    public static let manifestName = ".omniplay"

    struct Manifest: Codable {
        struct File: Codable {
            let path: String
            let size: Int64
            let modified: Double
        }

        let id: String
        var files: [File]
    }

    /// `Documents/Titles/Saves`.
    public let root: URL

    public init(root: URL) { self.root = root }

    /// The game's folder: the one whose manifest names `id` (so a renamed game keeps it), else one named after the
    /// title; a title another game already holds gets ` (<first 4 of id>)`.
    public func folder(for id: GameID, title: String) -> URL {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        if let own = folders.first(where: { Self.manifest(in: $0)?.id == id.description }) {
            return own
        }
        let name = Self.folderName(title)
        let plain = root.appending(path: name, directoryHint: .isDirectory)
        let owner = Self.manifest(in: plain)?.id
        guard fm.fileExists(atPath: plain.path(percentEncoded: false)), owner != nil, owner != id.description else { return plain }
        return root.appending(path: "\(name) (\(id.description.prefix(4).lowercased()))", directoryHint: .isDirectory)
    }

    /// The title without `/ : \ ? * " < > |` and leading dots, so it is one plain folder name.
    static func folderName(_ title: String) -> String {
        var name = String(title.filter { !"/:\\?*\"<>|".contains($0) && !$0.isNewline })
            .trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") {
            name.removeFirst()
        }
        return name.isEmpty ? "Game" : name
    }

    /// Replaces the mirror with clones of the real saves and a fresh manifest. Unless `force`, a mirror holding
    /// changes the player has not answered for is left alone, so a file dropped in mid-session is not wiped.
    @discardableResult
    public func write(from location: SaveLocation, id: GameID, title: String, force: Bool = false) throws -> URL {
        let fm = FileManager.default
        let folder = folder(for: id, title: title)
        if !force, !pendingChanges(in: folder).isEmpty {
            return folder
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let fresh = root.appending(path: ".\(folder.lastPathComponent).new-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        do {
            for source in [location.slots, location.persistent] where fm.fileExists(atPath: source.path(percentEncoded: false)) {
                try fm.copyItem(at: source, to: fresh.appending(path: source.lastPathComponent)) // APFS clones the files
            }
            let manifest = try Manifest(id: id.description, files: Self.files(in: fresh).map { .init(path: $0.0, size: $0.1, modified: $0.2) })
            try JSONEncoder().encode(manifest).write(to: fresh.appending(path: Self.manifestName), options: .atomic)
            if fm.fileExists(atPath: folder.path(percentEncoded: false)) {
                _ = try fm.replaceItemAt(folder, withItemAt: fresh)
            } else {
                try fm.moveItem(at: fresh, to: folder)
            }
        } catch {
            try? fm.removeItem(at: fresh)
            throw error
        }
        return folder
    }

    /// Files added or changed in the game's folder since the mirror was written, relative to it.
    public func pendingChanges(for id: GameID, title: String) -> [String] { pendingChanges(in: folder(for: id, title: title)) }

    func pendingChanges(in folder: URL) -> [String] {
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else { return [] }
        let known = Dictionary((Self.manifest(in: folder)?.files ?? []).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        return ((try? Self.files(in: folder)) ?? []).filter { path, size, modified in
            guard let old = known[path] else { return true }
            return old.size != size || abs(old.modified - modified) > 1
        }.map(\.0)
    }

    /// Copies the changed files into `staging`, at their paths in the mirror, for `SaveTransfer.importSaves`.
    public func stageChanges(for id: GameID, title: String, into staging: URL) throws -> Int {
        let folder = folder(for: id, title: title)
        let changes = pendingChanges(in: folder)
        for path in changes {
            let target = staging.appending(path: path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: folder.appending(path: path), to: target)
        }
        return changes.count
    }

    /// Regular files under `folder`: hidden files (`.omniplay`, `.DS_Store`, `._*`), `__MACOSX` and links are left
    /// out, and a linked folder is never entered, so nothing outside the mirror is ever read through it.
    static func files(in folder: URL) throws -> [(String, Int64, Double)] {
        var out: [(String, Int64, Double)] = []
        try LazyDirectoryWalker.walk(root: folder) { entry in
            if entry.isSymbolicLink {
                return .continue
            }
            if entry.isDirectory {
                return entry.url.lastPathComponent == "__MACOSX" ? .skipDescendants : .continue
            }
            let modified = (try? entry.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            out.append((entry.relativePath, entry.fileSize, modified.timeIntervalSince1970))
            return .continue
        }
        return out
    }

    /// The manifest is in a folder anyone with Files can edit: read within a small bound, and nil when unreadable.
    static func manifest(in folder: URL) -> Manifest? {
        (try? SmallFileGuard.read(folder.appending(path: manifestName), maxBytes: 4 << 20))
            .flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
    }
}
