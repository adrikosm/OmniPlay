import Diagnostics
import Foundation
import GameCore
import GameDetection
import GameImport
import GameStore
import OverlayVFS

/// The commit half of the import: install into `Games/<id>`, seal, index, register; or replace an existing game.
extension ImportPipeline {
    // MARK: Commit

    struct CommitPlan {
        let stagedRoot: URL, located: LocatedRoot, title: String, detection: DetectionResult
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
            OPLog.log(.importer, .info, "registered \(id) \(plan.title) as \(plan.detection.engine.rawValue)", session: session)
            return id
        } catch {
            try? OriginalGuard.unseal(originalRoot: paths.tier(.original, for: id))
            try? fm.removeItem(at: gameRoot)
            throw error
        }
    }

    /// Swaps an existing game's `Original/` for the new tree, keeping `.bak` until everything succeeded. Saves stay.
    func replace(_ id: GameID, with plan: CommitPlan) async throws -> GameID {
        let fm = FileManager.default
        let original = paths.tier(.original, for: id)
        let backup = paths.game(id).appending(path: "Original.bak", directoryHint: .isDirectory)
        try? fm.removeItem(at: backup)
        try? OriginalGuard.unseal(originalRoot: original)
        try fm.moveItem(at: original, to: backup)
        do {
            try install(plan, into: id)
            try register(plan, id: id, replacing: true)
            try? fm.removeItem(at: backup)
            OPLog.log(.importer, .info, "replaced \(id) with \(plan.title)", session: session)
            return id
        } catch {
            try? OriginalGuard.unseal(originalRoot: original)
            try? fm.removeItem(at: original)
            try? fm.moveItem(at: backup, to: original)
            try? OriginalGuard.seal(originalRoot: original, manifest: paths.game(id).appending(path: "original.manifest"))
            throw error
        }
    }

    /// Moves the staged tree into place, seals it, indexes it and writes game.json.
    private func install(_ plan: CommitPlan, into id: GameID) throws {
        let gameRoot = paths.game(id)
        let original = paths.tier(.original, for: id)
        try FileManager.default.moveItem(at: plan.stagedRoot, to: original)
        try OriginalGuard.seal(originalRoot: original, manifest: gameRoot.appending(path: "original.manifest"))
        try PathIndex.open(at: gameRoot.appending(path: "index.sqlite")).rebuild(layer: "original", root: original)
        let descriptor = GameDescriptor(
            id: id,
            title: plan.title,
            rootRelativePath: plan.located.relativePath,
            engine: plan.detection.engine,
            version: plan.detection.engineVersion.flatMap(EngineVersion.init(parsing:)),
            warnings: plan.located.sidecars.notes,
            confidence: plan.detection.confidence,
            evidence: plan.detection.evidence,
            identityHash: plan.fingerprint,
            grade: plan.detection.engine.tier == .refused ? .refused : .loadable
        )
        try JSONEncoder().encode(descriptor).write(to: gameRoot.appending(path: "game.json"), options: .atomic)
        if !plan.located.sidecars.files.isEmpty {
            try JSONEncoder().encode(plan.located.sidecars).write(to: gameRoot.appending(path: "sidecars.json"), options: .atomic)
        }
    }

    private func register(_ plan: CommitPlan, id: GameID, replacing: Bool = false) throws {
        var record = try (replacing ? store.games.fetch(id: id) : nil) ?? GameRecord(
            id: id,
            title: plan.title,
            engine: plan.detection.engine
        )
        record.title = plan.title
        record.engine = plan.detection.engine
        record.rootRelPath = plan.located.relativePath
        record.detectionConfidence = plan.detection.confidence
        record.compatibilityState = plan.detection.engine.tier == .refused ? .refused : .loadable
        record.installBytes = plan.bytes
        record.version = plan.detection.engineVersion
        if replacing {
            try store.games.update(record)
        } else {
            try store.games.insert(record)
        }
        _ = try store.detection.saveResult(.init(
            gameId: id,
            outcome: plan.detection.engine.rawValue,
            confidence: plan.detection.confidence,
            evidence: plan.detection.evidence,
            detectorVersions: ["rgss-archive-magic": "1"]
        ))
        let container = (try? ContainerSniffer.identify(plan.source.url).rawValue) ?? "unknown"
        _ = try store.imports.record(.init(
            gameId: id,
            sourceName: plan.source.url.lastPathComponent,
            container: container,
            sourceSha256: plan.fingerprint,
            bytes: plan.bytes,
            outcome: replacing ? "replaced" : "ok"
        ))
    }
}
