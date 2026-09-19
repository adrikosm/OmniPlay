import Diagnostics
import Foundation
import GameCore
import GameDetection
import GameImport
import GameStore
import OverlayVFS
import RuntimeCore

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
            OPLog.log(.importer, .info, "registered \(id) \(plan.title) as \(plan.report.descriptor.engine.rawValue)", session: session)
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

    /// Moves the staged tree into place, seals it, indexes it and writes game.json plus the full detection report.
    func install(_ plan: CommitPlan, into id: GameID) throws {
        let gameRoot = paths.game(id)
        let original = paths.tier(.original, for: id)
        try FileManager.default.moveItem(at: plan.stagedRoot, to: original)
        try OriginalGuard.seal(originalRoot: original, manifest: gameRoot.appending(path: "original.manifest"))
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
        if replacing {
            try store.games.update(record)
        } else {
            try store.games.insert(record)
        }
        _ = try store.detection.saveResult(.init(
            gameId: id,
            outcome: Self.outcomeName(plan.report.outcome),
            confidence: plan.report.confidence,
            evidence: plan.report.evidence.map(\.record),
            detectorVersions: plan.report.detectorVersions.mapValues(String.init)
        ))
        if let runtime = plan.resolution.selectedRuntime {
            _ = try store.runtime.saveSelection(.init(
                gameId: id,
                selectedRuntime: runtime,
                version: plan.resolution.selectedRuntimeVersion,
                reason: plan.resolution.reason,
                warnings: plan.resolution.warnings.map { "\($0)" },
                fallbacks: plan.resolution.fallbacks.map(\.runtime)
            ))
        }
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
