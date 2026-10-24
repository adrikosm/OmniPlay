import Foundation
import GameCore
import GameImport
import OverlayVFS

/// Web frontends kept inside a Windows program (Tauri), unpacked beside it at import and by a library re-check.
/// A change to what is unpacked here bumps `prepVersion`, so every game imported before it is re-checked once.
enum ProgramFrontends {
    static let prepVersion = 1

    /// Unpacks the first frontend found below `root` beside its program, or at the same relative place under
    /// `destination`. Nil when no program carries one.
    static func unpack(in root: URL, into destination: URL? = nil, limits: SafetyLimits) throws -> RunningTotals? {
        let base = root.standardizedFileURL.pathComponents.count
        for program in ImportPipeline.tauriCandidates(in: root) {
            let folder = program.deletingLastPathComponent()
            let target = destination.map { destination in
                folder.standardizedFileURL.pathComponents.dropFirst(base)
                    .reduce(destination) { $0.appending(path: $1, directoryHint: .isDirectory) }
            } ?? folder
            do {
                if let totals = try TauriExtractor(limits: limits).extract(program, to: target) {
                    return totals
                }
            } catch let v as SafetyViolation {
                throw ImportFailure.safetyViolation(v)
            }
        }
        return nil
    }

    /// Unpacks a frontend into an installed game's sealed `Original/`: into `scratch` first, then moved in beside what is
    /// there (never over it, as the extractor itself never overwrites), resealed with hashing deferred and re-indexed.
    /// Any failure puts the tree, the manifest and the index back as they were. Returns the number of files added.
    static func unpackInstalled(
        original: URL,
        indexRoot: URL,
        manifest: URL,
        index: URL,
        scratch: URL,
        limits: SafetyLimits
    ) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let unpacked = scratch.appending(path: "Original", directoryHint: .isDirectory)
        guard try unpack(in: original, into: unpacked, limits: limits) != nil else { return 0 }
        return try merge(unpacked, into: original, indexRoot: indexRoot, manifest: manifest, index: index, scratch: scratch)
    }

    /// The move half of `unpackInstalled`, on its own so a failure half-way can be tested without a program.
    static func merge(_ unpacked: URL, into original: URL, indexRoot: URL, manifest: URL, index: URL, scratch: URL) throws -> Int {
        let fm = FileManager.default
        var entries: [(rel: String, isDirectory: Bool)] = []
        try LazyDirectoryWalker.walk(root: unpacked, skipHidden: false) { entries.append(($0.relativePath, $0.isDirectory)); return .continue }
        let savedManifest = scratch.appending(path: "original.manifest")
        try fm.copyItem(at: manifest, to: savedManifest)
        var added: [URL] = []
        var files = 0
        var indexTouched = false
        do {
            try OriginalGuard.unseal(originalRoot: original)
            for entry in entries {
                let target = original.appending(path: entry.rel, directoryHint: entry.isDirectory ? .isDirectory : .notDirectory)
                guard !fm.fileExists(atPath: target.path(percentEncoded: false)) else { continue }
                if entry.isDirectory {
                    try fm.createDirectory(at: target, withIntermediateDirectories: false)
                } else {
                    try fm.moveItem(at: unpacked.appending(path: entry.rel), to: target)
                    files += 1
                }
                added.append(target)
            }
            try OriginalGuard.seal(originalRoot: original, manifest: manifest, hashing: .deferred)
            indexTouched = true
            try PathIndex.open(at: index).rebuild(layer: "original", root: indexRoot)
            return files
        } catch {
            try? OriginalGuard.unseal(originalRoot: original)
            for url in added.reversed() {
                try? fm.removeItem(at: url)
            }
            // Sealing writes a manifest: this one is thrown away, and the saved one goes back.
            try? OriginalGuard.seal(originalRoot: original, manifest: scratch.appending(path: "reseal.manifest"), hashing: .deferred)
            try? fm.removeItem(at: manifest)
            try? fm.copyItem(at: savedManifest, to: manifest)
            if indexTouched {
                try? PathIndex.open(at: index).rebuild(layer: "original", root: indexRoot)
            }
            throw error
        }
    }
}
