import Diagnostics
import Foundation
import GameCore
import GameImport
import SaveKit

/// Moves saves in and out of a game: ZIP export to the Files-visible folder, import of a ZIP, a folder or loose
/// save files. Every imported file is validated first; foreign or wrong-family saves need explicit confirmation.
struct SaveTransfer: Sendable {
    struct Target: Sendable {
        let id: GameID
        let title: String
        let engine: EngineFamily
        let family: SaveFamily
        let slotPattern: String?
        let identityHash: String
    }

    enum Collision: Sendable { case replace, nextFreeSlot }

    enum Outcome: Sendable, Equatable {
        case installed(slots: Int, persistent: Int)
        /// Nothing was installed; the caller shows these and retries with `confirmed: true`.
        case needsConfirmation([String])
        case nothingRecognised([String])
    }

    static let saveExtensions: Set<String> = ["rpgsave", "rmmzsave", "rxdata", "rvdata", "rvdata2", "save", "lsd", "webstorage"]

    let paths: AppPaths
    let target: Target
    var location: SaveLocation { SaveLocation.forGame(target.id, paths: paths) }

    /// `Documents/OmniPlay/Saves-Export/<title>-<date>.zip`, visible in Files.
    func export() async throws -> URL {
        try location.ensure()
        let stamp = Date.now.formatted(.iso8601.year().month().day().timeZone(separator: .omitted).time(includingFractionalSeconds: false))
            .replacingOccurrences(
                of: ":",
                with: ""
            )
        let safeTitle = target.title.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_")).inverted)
            .joined().trimmingCharacters(in: .whitespaces)
        let destination = paths.exportsRoot.appending(path: "\(safeTitle.isEmpty ? "saves" : safeTitle)-\(stamp).zip")
        try FileManager.default.createDirectory(at: paths.exportsRoot, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let staging = location.root.appending(path: ".export-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for name in ["slots", "persistent"]
            where FileManager.default.fileExists(atPath: location.root.appending(path: name).path(percentEncoded: false)) {
            try await APFSClone.clone(from: location.root.appending(path: name), to: staging.appending(path: name))
        }
        let manifest = try SaveExportManifest(
            engine: target.engine, family: target.family, gameID: target.id, titleHash: target.identityHash, title: target.title,
            entries: SaveExportManifest.entries(for: SaveLocation(savesRoot: staging))
        )
        try ArchiveWriter().zip(directory: staging, to: destination, extras: [(SaveExportManifest.fileName, encoder.encode(manifest))])
        OPLog.log(.save, .info, "exported saves of \(target.title) → \(destination.lastPathComponent)")
        return destination
    }

    /// The import's files under `staging/tree`: a folder copied, a ZIP extracted through the import's safety limits,
    /// or a single file placed as a slot.
    private static func stage(_ source: URL, into staging: URL) throws -> URL {
        let fm = FileManager.default
        let tree = staging.appending(path: "tree")
        var isDir: ObjCBool = false
        fm.fileExists(atPath: source.path(percentEncoded: false), isDirectory: &isDir)
        if isDir.boolValue {
            try fm.copyItem(at: source, to: tree)
        } else if !saveExtensions.contains(source.pathExtension.lowercased()), (try? ContainerSniffer.identify(source)) == .zip {
            // A Ren'Py `.save` is itself a ZIP; picked on its own it is one save, not an archive of them.
            _ = try LibArchiveExtractor().extract(source, to: tree)
        } else {
            try fm.createDirectory(at: tree.appending(path: "slots"), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: tree.appending(path: "slots/\(source.lastPathComponent)"))
        }
        return tree
    }

    /// Imports from a ZIP, a folder or a single save file. Nothing is written unless every file is recognised and,
    /// when a warning applies, `confirmed` is true.
    func importSaves(from source: URL, collision: Collision, confirmed: Bool) async throws -> Outcome {
        let fm = FileManager.default
        let staging = paths.tier(.importStaging, for: target.id).appending(path: "saves-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let tree = try Self.stage(source, into: staging)
        var manifest: SaveExportManifest?
        var slotFiles: [URL] = []
        var persistentFiles: [(URL, String)] = []
        try LazyDirectoryWalker.walk(root: tree) { entry in
            guard !entry.isDirectory else { return .continue }
            if entry.url.lastPathComponent == SaveExportManifest.fileName {
                // From an untrusted archive: read within the small-file bound, never whole.
                manifest = (try? SmallFileGuard.read(entry.url, maxBytes: 1 << 20)).flatMap { try? JSONDecoder().decode(
                    SaveExportManifest.self,
                    from: $0
                ) }
            } else if let range = entry.relativePath.range(of: "persistent/") {
                persistentFiles.append((entry.url, String(entry.relativePath[range.upperBound...])))
            } else if Self.saveExtensions.contains(entry.url.pathExtension.lowercased()) || entry.relativePath.contains("slots/") {
                slotFiles.append(entry.url)
            }
            return .continue
        }
        guard !slotFiles.isEmpty || !persistentFiles.isEmpty
        else { return .nothingRecognised(["No save files found in \(source.lastPathComponent)."]) }
        var warnings: [String] = []
        var refused: [String] = []
        for file in slotFiles {
            let v = SaveValidator.validate(
                file: file,
                family: target.family,
                expectedTitleHash: target.identityHash,
                manifestTitleHash: manifest?.titleHash
            )
            if !v.isAcceptable {
                refused.append("\(file.lastPathComponent): \(v.warnings.first ?? "unrecognised")"); continue
            }
            if !v
                .matchesFamily {
                warnings.append("\(file.lastPathComponent) is a \(v.format.rawValue) save; this game uses \(target.family.rawValue).")
            }
            if case let .foreign(hash) = v
                .titleMatch {
                warnings
                    .append(
                        "\(file.lastPathComponent) was exported from a different game (\(hash.prefix(12))). Loading it here can misbehave."
                    )
            }
        }
        if let manifest, manifest.titleHash != target.identityHash, !warnings.contains(where: { $0.contains("different game") }) {
            warnings.append("This export came from \"\(manifest.title)\", not from \(target.title).")
        }
        guard refused.isEmpty else { return .nothingRecognised(refused) }
        if !warnings.isEmpty, !confirmed {
            return .needsConfirmation(Array(Set(warnings)).sorted())
        }

        let existing = Set((try? fm.contentsOfDirectory(atPath: location.slots.path(percentEncoded: false))) ?? [])
        var occupied = existing.union(slotFiles.map(\.lastPathComponent))
        var plan: [(URL, URL)] = []
        for file in slotFiles {
            var name = file.lastPathComponent
            if collision == .nextFreeSlot, existing.contains(name) || plan.contains(where: { $0.1.lastPathComponent == name }) {
                guard let free = SlotNaming.duplicateName(for: name, existing: occupied, pattern: target.slotPattern) else {
                    throw RestoreError.noFreeSlot(name)
                }
                name = free
            }
            occupied.insert(name)
            plan.append((file, location.slots.appending(path: name)))
        }
        for (file, rel) in persistentFiles {
            plan.append((file, location.persistent.appending(path: rel)))
        }
        try location.ensure()
        let txn = SafePersistTransaction(location: location, identityHash: target.identityHash)
        let mapping = plan
        try await txn.run(targets: mapping.map(\.1), reason: .imported) { staging in
            for (file, destination) in mapping {
                let staged = staging.url(for: destination)
                try? FileManager.default.removeItem(at: staged)
                try FileManager.default.copyItem(at: file, to: staged)
            }
        }
        OPLog.log(.save, .info, "imported \(plan.count) save files into \(target.title)")
        return .installed(slots: plan.count - persistentFiles.count, persistent: persistentFiles.count)
    }
}
