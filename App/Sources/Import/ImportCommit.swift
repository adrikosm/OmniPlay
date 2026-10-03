import Diagnostics
import Foundation
import GameCore
import GameDetection
import GameImport
import GameStore
import OverlayVFS
import RuntimeCore
import SaveKit
import Synchronization

/// The commit half of the import: install into `Games/<id>`, seal, index, persist the report; or replace an existing game.
extension ImportPipeline {
    struct CommitPlan {
        let stagedRoot: URL, located: LocatedRoot, title: String, report: DetectionReport, resolution: RuntimeResolution
        let bytes: Int64, source: ImportSource, fingerprint: String
    }

    func commit(_ plan: CommitPlan) async throws -> GameID {
        let id = GameID()
        let gameRoot = paths.game(id)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: gameRoot, withIntermediateDirectories: true)
            for tier in [ContentTier.overrides, .generated, .saves, .artwork] {
                try fm.createDirectory(at: paths.tier(tier, for: id), withIntermediateDirectories: true)
            }
            try install(plan, into: id)
            try register(plan, id: id)
            attachCover(plan, id: id)
            restoreRescuedSaves(plan, id: id)
            OPLog.log(.importer, .info, "registered \(id) \(plan.title) as \(plan.report.descriptor.engine.rawValue)", session: session)
            return id
        } catch {
            try? OriginalGuard.unseal(originalRoot: paths.tier(.original, for: id))
            try? fm.removeItem(at: gameRoot)
            try? fm.removeItem(at: paths.logs(game: id, session: UUID()).deletingLastPathComponent())
            throw error
        }
    }

    /// Games a replacement or a deletion is working on. Each claims the id first, so a delete never removes the tree or
    /// the rollback backup under a replacement (both run off the import queue's order).
    private static let busy = Mutex<Set<GameID>>([])
    static func claim(_ id: GameID) -> Bool { busy.withLock { $0.insert(id).inserted } }
    static func release(_ id: GameID) { _ = busy.withLock { $0.remove(id) } }

    /// Keep the original tree and every affected sidecar until the database transaction succeeds. Saves stay.
    func replace(_ id: GameID, with plan: CommitPlan) async throws -> GameID {
        guard Self.claim(id) else { throw ImportFailure.internalError("The game is being deleted, so it was not replaced.") }
        defer { Self.release(id) }
        // Deleted while this import was staging: nothing to replace, and no folder is recreated for it.
        guard try store.games.fetch(id: id) != nil else {
            throw ImportFailure.internalError("The game was deleted while this import was running, so there is nothing to replace.")
        }
        let fm = FileManager.default
        let r = ReplacementPaths(id, paths: paths)
        let original = r.original, backup = r.backup, metadata = r.metadata, index = r.index
        guard !fm.fileExists(atPath: backup.path(percentEncoded: false)) else {
            throw ImportFailure
                .internalError("A previous replacement needs recovery; its backup was preserved at \(backup.lastPathComponent).")
        }
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        do {
            for url in metadata where fm.fileExists(atPath: url.path(percentEncoded: false)) {
                try fm.copyItem(at: url, to: backup.appending(path: url.lastPathComponent))
            }
            try PathIndex.open(at: index).backup(to: backup.appending(path: "index.sqlite"))
            // Darwin requires write permission on a directory moved between parents; leave its contents sealed.
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: original.path(percentEncoded: false))
            try fm.moveItem(at: original, to: backup.appending(path: "Original"))
        } catch {
            try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: original.path(percentEncoded: false))
            try? fm.removeItem(at: backup)
            throw error
        }
        do {
            try install(plan, into: id)
            try register(plan, id: id, replacing: true)
            // Committed: the backup is renamed at once, so a launch after a kill here never restores it over the new row.
            // ponytail: the rename right after the database commit is the remaining window; a journal row closes it.
            let done = paths.game(id).appending(path: Self.committedRollback, directoryHint: .isDirectory)
            Self.removeSealed(done)
            if (try? fm.moveItem(at: backup, to: done)) != nil {
                Self.removeSealed(done)
            }
            discardGenerated(id)
            attachCover(plan, id: id)
            OPLog.log(.importer, .info, "replaced \(id) with \(plan.title)", session: session)
            return id
        } catch {
            let failure = error
            do { try Self.restoreReplacement(id, paths: paths) } catch {
                throw ImportFailure
                    .internalError("Replacement failed (\(failure)); recovery failed (\(error)). Preserved ImportRollback for recovery.")
            }
            throw failure
        }
    }

    static let committedRollback = "ImportRollback-done"

    /// Where a replacement keeps the game it replaces until the new one is registered.
    struct ReplacementPaths {
        let original: URL, backup: URL, metadata: [URL], index: URL

        init(_ id: GameID, paths: AppPaths) {
            let root = paths.game(id)
            original = paths.tier(.original, for: id)
            backup = root.appending(path: "ImportRollback", directoryHint: .isDirectory)
            metadata = ["game.json", "original.manifest", "sidecars.json"].map { root.appending(path: $0) }
                + [paths.logs(game: id, session: UUID()).deletingLastPathComponent().appending(path: "detection.json")]
            index = root.appending(path: "index.sqlite")
        }
    }

    /// Puts the replaced game back from `ImportRollback`: when a replacement fails, and at launch for one the app died
    /// in. A backup without `Original/` was never swapped in, so only the backup goes.
    static func restoreReplacement(_ id: GameID, paths: AppPaths) throws {
        let fm = FileManager.default
        let r = ReplacementPaths(id, paths: paths)
        let original = r.original, backup = r.backup, metadata = r.metadata, index = r.index
        let saved = backup.appending(path: "Original", directoryHint: .isDirectory)
        if fm.fileExists(atPath: saved.path(percentEncoded: false)) {
            if fm.fileExists(atPath: original.path(percentEncoded: false)) {
                try OriginalGuard.unseal(originalRoot: original)
                try fm.removeItem(at: original)
            }
            try fm.moveItem(at: saved, to: original)
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: original.path(percentEncoded: false))
            try PathIndex.open(at: backup.appending(path: "index.sqlite")).backup(to: index)
            for url in metadata {
                if fm.fileExists(atPath: url.path(percentEncoded: false)) {
                    try fm.removeItem(at: url)
                }
                let copy = backup.appending(path: url.lastPathComponent)
                if fm.fileExists(atPath: copy.path(percentEncoded: false)) {
                    try fm.copyItem(at: copy, to: url)
                }
            }
        }
        try fm.removeItem(at: backup)
    }

    /// At launch, before anything reads a game: finishes every replacement the app was killed in the middle of.
    static func recoverReplacements(paths: AppPaths) {
        let games = (try? FileManager.default.contentsOfDirectory(at: paths.games(), includingPropertiesForKeys: nil)) ?? []
        for folder in games {
            guard let id = GameID(uuidString: folder.lastPathComponent) else { continue }
            removeSealed(folder.appending(path: committedRollback, directoryHint: .isDirectory))
            guard FileManager.default.fileExists(atPath: ReplacementPaths(id, paths: paths).backup.path(percentEncoded: false))
            else { continue }
            do {
                try restoreReplacement(id, paths: paths)
                OPLog.log(.importer, .info, "restored \(id) from an interrupted replacement")
            } catch {
                OPLog.log(.importer, .error, "could not restore \(id) from its ImportRollback: \(error)")
            }
        }
    }

    /// Removes a backup folder whose `Original/` is still sealed (a plain remove fails on 0o555 folders).
    static func removeSealed(_ folder: URL) {
        try? OriginalGuard.unseal(originalRoot: folder.appending(path: "Original", directoryHint: .isDirectory))
        try? FileManager.default.removeItem(at: folder)
    }

    /// Fills in the manifest's hashes at background priority once the game is in the library (the import queue calls
    /// it when a run ends). A game deleted or replaced meanwhile just ends the pass; its manifest is never overwritten
    /// with another tree's lines.
    func completeHashingLater(_ id: GameID) {
        let original = paths.tier(.original, for: id)
        let manifest = paths.game(id).appending(path: "original.manifest")
        let session = session
        Task.detached(priority: .background) {
            do {
                try await OriginalGuard.completeDeferredHashing(originalRoot: original, manifest: manifest)
                OPLog.log(.importer, .info, "hashed the originals of \(id)", session: session)
            } catch {
                OPLog.log(.importer, .default, "originals of \(id) left unhashed: \(error)", session: session)
            }
        }
    }

    /// Everything in Generated was derived from the replaced files: media converted from the old release (whose cached
    /// plan would otherwise be reused, serving the old videos and never scanning the new ones) and a composed plugin
    /// list. It is rebuilt from the new files at the next launch.
    func discardGenerated(_ id: GameID) {
        let fm = FileManager.default
        let generated = paths.tier(.generated, for: id)
        do {
            if fm.fileExists(atPath: generated.path(percentEncoded: false)) {
                try fm.removeItem(at: generated)
            }
            try fm.createDirectory(at: generated, withIntermediateDirectories: true)
            try PathIndex.open(at: paths.game(id).appending(path: "index.sqlite")).invalidate(layer: "generated")
        } catch {
            OPLog.log(.importer, .error, "generated files of the replaced game not cleared: \(error)", session: session)
        }
    }

    /// Moves the staged tree into place, seals it, indexes it and writes game.json plus the full detection report.
    /// The manifest's hashes wait (`completeHashingLater`): hashing read every byte of the game a second time before it
    /// could appear in the library, and nothing needs them while it is being played.
    func install(_ plan: CommitPlan, into id: GameID) throws {
        let gameRoot = paths.game(id)
        let original = paths.tier(.original, for: id)
        try FileManager.default.moveItem(at: plan.stagedRoot, to: original)
        try OriginalGuard.seal(originalRoot: original, manifest: gameRoot.appending(path: "original.manifest"), hashing: .deferred)
        let located = plan.located.relativePath.isEmpty ? original : original.appending(
            path: plan.located.relativePath,
            directoryHint: .isDirectory
        )
        try PathIndex.open(at: gameRoot.appending(path: "index.sqlite")).rebuild(layer: "original", root: located)
        var d = plan.report.descriptor
        d = GameDescriptor(
            id: id,
            title: plan.title,
            rootRelativePath: d.rootRelativePath,
            engine: d.engine,
            generation: d.generation,
            version: d.version,
            runtimeCandidates: d.runtimeCandidates,
            entryPoint: d.entryPoint,
            containerType: try? ContainerSniffer.identify(plan.source.url).rawValue,
            saveFamily: d.saveFamily,
            exportPlatform: d.exportPlatform,
            mediaRequirements: d.mediaRequirements,
            blockers: d.blockers,
            warnings: d.warnings + plan.located.sidecars.notes.map { .note($0) },
            capabilities: d.capabilities,
            confidence: d.confidence,
            evidence: d.evidence,
            identityHash: plan.fingerprint,
            grade: d.grade,
            profile: d.profile
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(d).write(to: gameRoot.appending(path: "game.json"), options: .atomic)
        let logs = paths.logs(game: id, session: UUID()).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        var report = plan.report
        report.descriptor = d
        try encoder.encode(DetectionSnapshot(report: report, resolution: plan.resolution)).write(
            to: logs.appending(path: "detection.json"),
            options: .atomic
        )
        if !plan.located.sidecars.files.isEmpty {
            try encoder.encode(plan.located.sidecars).write(to: gameRoot.appending(path: "sidecars.json"), options: .atomic)
        } else if FileManager.default.fileExists(atPath: gameRoot.appending(path: "sidecars.json").path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: gameRoot.appending(path: "sidecars.json"))
        }
    }

    func register(_ plan: CommitPlan, id: GameID, replacing: Bool = false) throws {
        let d = plan.report.descriptor
        var record = try (replacing ? store.games.fetch(id: id) : nil) ?? GameRecord(id: id, title: plan.title, engine: d.engine)
        record.title = plan.title
        record.engine = d.engine
        record.generation = d.generation
        record.version = d.version?.raw
        record.runtime = plan.resolution.selectedRuntime
        record.runtimeVersion = plan.resolution.selectedRuntimeVersion
        record.rootRelPath = plan.located.relativePath
        record.detectionConfidence = plan.report.confidence
        record.compatibilityState = plan.report.outcome.isPlayableClass ? .loadable : .refused
        record.installBytes = plan.bytes
        record.compatProfileJson = d.profile
        let detection = DetectionResultRecord(
            gameId: id,
            outcome: Self.outcomeName(plan.report.outcome),
            confidence: plan.report.confidence,
            evidence: plan.report.evidence.map(\.record),
            detectorVersions: plan.report.detectorVersions.mapValues(String.init)
        )
        let runtime = plan.resolution.selectedRuntime.map { runtime in
            RuntimeSelectionRecord(
                gameId: id,
                selectedRuntime: runtime,
                version: plan.resolution.selectedRuntimeVersion,
                reason: plan.resolution.reason,
                warnings: plan.resolution.warnings.map { "\($0)" },
                fallbacks: plan.resolution.fallbacks.map(\.runtime)
            )
        }
        let container = (try? ContainerSniffer.identify(plan.source.url).rawValue) ?? "unknown"
        let source = ImportRecord(
            gameId: id,
            sourceName: plan.source.url.lastPathComponent,
            container: container,
            sourceSha256: plan.fingerprint,
            bytes: plan.bytes,
            outcome: replacing ? "replaced" : "ok"
        )
        try store.registerImport(game: record, detection: detection, runtime: runtime, source: source, replacing: replacing)
    }

    /// Saves kept from a deleted copy of the same title come back automatically; the game is new, so nothing is overwritten.
    func restoreRescuedSaves(_ plan: CommitPlan, id: GameID) {
        guard let rescue = RescuedSaves.find(titleHash: plan.fingerprint, paths: paths).first else { return }
        do {
            try RescuedSaves.restore(from: rescue.directory, into: SaveLocation.forGame(id, paths: paths))
            OPLog.log(.importer, .info, "restored rescued saves for \(plan.title)", session: session)
        } catch {
            OPLog.log(.importer, .error, "rescued saves not restored: \(error)", session: session)
        }
    }

    /// Best-effort: a missing cover is a placeholder, never a failed import.
    func attachCover(_ plan: CommitPlan, id: GameID) {
        let engine = plan.report.descriptor.engine
        guard let path = CoverExtractor.extract(game: id, engine: engine, rootRelativePath: plan.located.relativePath, paths: paths),
              var record = try? store.games.fetch(id: id) else { return }
        record.artworkPath = path
        try? store.games.update(record)
    }

    static func outcomeName(_ o: DetectionOutcome) -> String {
        switch o {
        case .supported: "supported"
        case .supportedWithLimitations: "supportedWithLimitations"
        case .experimental: "experimental"
        case .unknownVersion: "unknownVersion"
        case .unknownEngine: "unknownEngine"
        case .unsupported: "unsupported"
        case .refused: "refused"
        }
    }
}

/// What the detail screen reads back: the report and how it resolved.
struct DetectionSnapshot: Codable, Sendable {
    var report: DetectionReport
    var resolution: RuntimeResolution
}
