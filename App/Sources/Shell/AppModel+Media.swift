import Diagnostics
import Foundation
import GameCore
import GameStore
import MediaCompat
import MediaTranscode
import OverlayVFS
import Synchronization

/// Set when the player leaves while media is being prepared; read from the conversion thread.
final class MediaCancel: Sendable {
    private let flag = Mutex(false)
    var isSet: Bool { flag.withLock { $0 } }
    func set(_ value: Bool) { flag.withLock { $0 = value } }
}

/// Media preparation before a game starts: what its engine cannot decode is converted into Generated first
/// (`MediaPreparation`), with progress on the player screen. Runs once per game and engine; later launches find the
/// marker and the outputs and go straight on.
extension AppModel {
    struct MediaStatus: Equatable {
        var index: Int
        var count: Int
        var file: String
        /// Of the current file; -1 while its length is unknown.
        var fraction: Double

        var line: String {
            let name = (file as NSString).lastPathComponent
            let percent = fraction >= 0 ? " \(Int(fraction * 100))%" : ""
            return count > 1 ? "Preparing media \(index + 1) of \(count): \(name)\(percent)" : "Preparing \(name)\(percent)"
        }
    }

    struct PreparedMedia {
        /// Name the game uses (lower-cased, game-relative) → converted file, relative to Generated.
        var remap: [String: String] = [:]
        var failed = 0
    }

    static func mediaEngine(for runtime: RuntimeIdentifier?) -> MediaEngine? {
        switch runtime {
        case .web?: .webKit
        case .rgss?: .mkxp
        case .renpy?: .renpy
        default: nil
        }
    }

    /// Converts what `runtime` cannot play and returns the name map the runtime needs. Leaving the player screen
    /// while this runs stops it after the current file's next progress tick; finished files stay.
    func prepareMedia(for game: GameID, runtime: RuntimeIdentifier?, gameRoot: URL, indexURL: URL) async -> PreparedMedia {
        let cancel = mediaCancel // unique to this launch; a later launch cannot revive canceled work
        guard let engine = Self.mediaEngine(for: runtime) else { return PreparedMedia() }
        let generated = paths.tier(.generated, for: game)
        let (updates, continuation) = AsyncStream.makeStream(of: MediaPreparation.Progress.self, bufferingPolicy: .bufferingNewest(1))
        let progressTask = Task {
            for await progress in updates {
                guard !Task.isCancelled, mediaCancel === cancel, !cancel.isSet else { return }
                preparingMedia = MediaStatus(index: progress.index, count: progress.count, file: progress.file, fraction: progress.fraction)
            }
        }
        defer {
            continuation.finish()
            progressTask.cancel()
            preparingMedia = nil
        }
        let report: @Sendable (MediaPreparation.Progress) -> Bool = { progress in
            continuation.yield(progress)
            return !cancel.isSet
        }
        let started = ContinuousClock.now
        let work = Task.detached(priority: .userInitiated) { () -> (MediaPreparation.Plan, Int) in
            let plan = MediaPreparation.plan(gameRoot: gameRoot, generatedRoot: generated, engine: engine)
            let todo = MediaPreparation.pending(plan, generatedRoot: generated).count
            guard todo > 0, !cancel.isSet else { return (plan, 0) }
            let done = MediaPreparation.run(plan, gameRoot: gameRoot, generatedRoot: generated, progress: report)
            // The runtimes resolve through the index; the new files must be in it before the game asks for them.
            try? PathIndex.open(at: indexURL).rebuild(layer: "generated", root: generated)
            return (done, todo)
        }
        let (plan, converted) = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            cancel.set(true)
            work.cancel()
        }
        preparingMedia = nil
        if converted > 0 {
            OPLog.log(
                .media,
                .info,
                "prepared \(converted) media files for \(engine.rawValue) in \(started.duration(to: .now)); \(plan.failed.count) failed"
            )
            recordMediaJobs(plan, game: game, generated: generated)
        }
        return PreparedMedia(remap: MediaPreparation.remap(plan, generatedRoot: generated), failed: plan.failed.count)
    }

    /// Stops a preparation in progress (the player left before the game appeared).
    func cancelMediaPreparation() { mediaCancel.set(true) }

    /// What Diagnostics lists per game: each conversion, done or failed, with its size.
    private func recordMediaJobs(_ plan: MediaPreparation.Plan, game: GameID, generated: URL) {
        guard let store else { return }
        let existing = Dictionary(
            ((try? store.fetchAll(MediaJobRecord.self, game: game)) ?? []).map { ($0.inputRel, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for c in plan.conversions {
            var record = existing[c.source] ?? MediaJobRecord(
                gameId: game,
                inputRel: c.source,
                outputRel: c.output,
                sourceCodec: MediaRules.pathExtension(c.source),
                targetCodec: c.target.rawValue,
                targetRuntime: plan.engine.rawValue,
                reason: "\(plan.engine.rawValue) cannot play .\(MediaRules.pathExtension(c.source))",
                state: "pending"
            )
            let exists = FileManager.default.fileExists(atPath: generated.appending(path: c.output).path(percentEncoded: false))
            record.state = plan.failed[c.source] != nil ? "failed" : exists ? "done" : "pending"
            record.error = plan.failed[c.source]
            record.progress = record.state == "done" ? 1 : 0
            record.bytesOut = Int64((try? generated.appending(path: c.output).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if record.id == nil {
                _ = try? store.insert(record)
            } else {
                try? store.update(record)
            }
        }
    }
}
