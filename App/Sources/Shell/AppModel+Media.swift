import Diagnostics
import Foundation
import GameCore
import GameStore
import MediaCompat
import MediaTranscode
import OverlayVFS
import Synchronization
import UIKit

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
        var cooling = false

        var line: String {
            if cooling {
                return "Waiting for the phone to cool down before converting more media…"
            }
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

    /// Settings → "Prepare media before first play". Off, games start at once and play what their engine can.
    static let prepareBeforePlayKey = "omniplay.media.prepareBeforePlay"
    static var prepareBeforePlay: Bool { UserDefaults.standard.object(forKey: prepareBeforePlayKey) as? Bool ?? true }

    /// Converts what `runtime` cannot play and returns the name map the runtime needs. Leaving the player screen
    /// while this runs stops it after the current file's next progress tick, and so does "Play anyway", which then
    /// starts the game with what is ready; finished files stay either way.
    func prepareMedia(for game: GameID, runtime: RuntimeIdentifier?, gameRoot: URL, indexURL: URL) async -> PreparedMedia {
        let (cancel, skip) = (mediaCancel, mediaSkip) // unique to this launch; a later launch cannot revive canceled work
        guard let engine = Self.mediaEngine(for: runtime) else { return PreparedMedia() }
        let generated = paths.tier(.generated, for: game)
        // A conversion started after the import hands over: it stops at its next tick, its finished files stay.
        if let prewarm = mediaPrewarm.removeValue(forKey: game) {
            prewarm.cancel()
            await prewarm.value
        }
        let convert = Self.prepareBeforePlay
        let (updates, continuation) = AsyncStream.makeStream(of: MediaPreparation.Progress.self, bufferingPolicy: .bufferingNewest(1))
        let progressTask = Task {
            for await progress in updates {
                guard !Task.isCancelled, mediaCancel === cancel, !cancel.isSet else { return }
                preparingMedia = MediaStatus(
                    index: progress.index,
                    count: progress.count,
                    file: progress.file,
                    fraction: progress.fraction,
                    cooling: progress.cooling
                )
            }
        }
        defer {
            continuation.finish()
            progressTask.cancel()
            preparingMedia = nil
        }
        let report: @Sendable (MediaPreparation.Progress) -> Bool = { progress in
            continuation.yield(progress)
            return !cancel.isSet && !skip.isSet
        }
        let started = ContinuousClock.now
        // Sent to the background mid-file, the conversion gets the time iOS allows to finish it, then stops cleanly.
        let background = UIApplication.shared.beginBackgroundTask(withName: "Prepare media") { skip.set(true) }
        let work = Task.detached(priority: .userInitiated) {
            Self.convert(engine: engine, gameRoot: gameRoot, generated: generated, indexURL: indexURL, run: convert, progress: report)
        }
        let (plan, converted) = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            cancel.set(true)
            work.cancel()
        }
        UIApplication.shared.endBackgroundTask(background)
        preparingMedia = nil
        if converted > 0 {
            OPLog.log(
                .media,
                .info,
                (cancel.isSet ? "left during preparation of \(converted) media files"
                    : skip.isSet ? "started without waiting for \(converted) media files" : "prepared \(converted) media files")
                    + " for \(engine.rawValue) in \(started.duration(to: .now)); \(plan.failed.count) failed"
            )
            recordMediaJobs(plan, game: game, generated: generated)
        }
        return PreparedMedia(remap: MediaPreparation.remap(plan, generatedRoot: generated), failed: plan.failed.count)
    }

    /// Stops a preparation in progress (the player left before the game appeared).
    func cancelMediaPreparation() { mediaCancel.set(true) }

    /// "Play anyway": stops converting and starts the game with what is ready; the rest is converted next time.
    func skipMediaPreparation() { mediaSkip.set(true) }

    /// The plan, and with `run` its pending conversions, then the index rebuilt so runtimes resolve the new files.
    /// Returns how many conversions were pending.
    nonisolated static func convert(
        engine: MediaEngine,
        gameRoot: URL,
        generated: URL,
        indexURL: URL,
        run: Bool,
        progress: @escaping @Sendable (MediaPreparation.Progress) -> Bool
    ) -> (MediaPreparation.Plan, Int) {
        let plan = MediaPreparation.plan(gameRoot: gameRoot, generatedRoot: generated, engine: engine)
        let todo = MediaPreparation.pending(plan, generatedRoot: generated).count
        guard run, todo > 0 else { return (plan, 0) }
        let done = MediaPreparation.run(plan, gameRoot: gameRoot, generatedRoot: generated, progress: progress)
        try? PathIndex.open(at: indexURL).rebuild(layer: "generated", root: generated)
        return (done, todo)
    }

    /// Right after an import, converts the new game's media in the background so its first Play starts at once.
    /// Skipped when the Settings switch is off; a Play before it finishes takes over (`prepareMedia`).
    func prepareMediaInBackground(for id: GameID) {
        guard Self.prepareBeforePlay, mediaPrewarm[id] == nil, let record = try? store?.games.fetch(id: id),
              let engine = Self.mediaEngine(for: record.runtime), let snapshot = Self.snapshot(for: id, paths: paths) else { return }
        let descriptor = snapshot.report.descriptor.withID(id)
        let gameRoot = LayerSetBuilder.forGame(descriptor, paths: paths).first { $0.tier == .original }?.root
            ?? paths.tier(.original, for: id)
        let (generated, indexURL) = (paths.tier(.generated, for: id), paths.game(id).appending(path: "index.sqlite"))
        let work = Task.detached(priority: .utility) {
            Self.convert(engine: engine, gameRoot: gameRoot, generated: generated, indexURL: indexURL, run: true) { _ in
                !Task.isCancelled
            }
        }
        mediaPrewarm[id] = Task { [weak self] in
            let (plan, converted) = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, converted > 0 else { return }
            if Task.isCancelled { // Play took over; it records the jobs
                OPLog.log(.media, .info, "media conversion after import handed over to Play")
                return
            }
            OPLog.log(.media, .info, "converted \(converted) media files after import for \(engine.rawValue); \(plan.failed.count) failed")
            recordMediaJobs(plan, game: id, generated: generated)
            mediaPrewarm[id] = nil
        }
    }

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
