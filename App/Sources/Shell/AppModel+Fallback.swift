import Diagnostics
import Foundation
import GameCore
import GameDetection
import GameStore
import RuntimeCore

/// Bounded runtime fallback: a game whose engine refuses it at boot gets one retry on a sibling engine (Ren'Py
/// versions, Ruby lines, Godot buckets), never more. When the retry plays for the boot window, the sibling becomes the
/// game's runtime, with the reason recorded; otherwise both failures stay in the session logs.
extension AppModel {
    struct FallbackAttempt: Codable {
        let first: RuntimeIdentifier
        let category: FailureCategory
        let candidate: RuntimeIdentifier
        var result: String
        let at: Date
    }

    /// The runtime to retry with after `failure`, or nil. Marks the game as tried for this app launch either way a
    /// candidate is returned, so a second failure cannot start a loop.
    func fallbackCandidate(
        for record: GameRecord,
        snapshot: DetectionSnapshot,
        failure: FailureCategory,
        elapsed: Duration
    ) async -> RuntimeIdentifier? {
        let resolution = await freshResolution(for: record, snapshot: snapshot)
        let spent = spentSlots
        var available: Set<RuntimeIdentifier> = []
        for candidate in resolution.fallbacks {
            if let descriptor = await registry.descriptor(for: candidate.runtime), descriptor.availability != .notBuilt {
                available.insert(candidate.runtime)
            }
        }
        guard let candidate = FallbackPolicy.decide(
            failure: failure, elapsed: elapsed, resolution: resolution,
            alreadyTried: fallbackTried.contains(record.id),
            available: { available.contains($0) },
            slotFree: { !spent.contains($0) }
        ), let first = resolution.selectedRuntime else { return nil }
        fallbackTried.insert(record.id)
        pendingFallback[record.id] = candidate.runtime
        recordFallback(
            FallbackAttempt(first: first, category: failure, candidate: candidate.runtime, result: "trying", at: .now),
            for: record.id
        )
        OPLog.log(.runtime, .default, "fallback: \(first) failed (\(failure.rawValue)); trying \(candidate.runtime) once")
        return candidate.runtime
    }

    /// Called when a fallback session has played through the boot window: the sibling becomes the game's runtime.
    func fallbackSucceeded(for id: GameID) async {
        guard let runtime = pendingFallback.removeValue(forKey: id) else { return }
        _ = await chooseRuntime(runtime, for: id)
        if var attempt = lastFallback(for: id) {
            attempt.result = "fallback succeeded on \(Date.now.formatted(date: .abbreviated, time: .shortened))"
            recordFallback(attempt, for: id)
        }
        OPLog.log(.runtime, .info, "fallback: \(runtime) kept as this game's runtime")
    }

    /// The fallback failed too: nothing is kept, and the game will not fall back again this launch.
    func fallbackFailed(for id: GameID) {
        guard pendingFallback.removeValue(forKey: id) != nil else { return }
        if var attempt = lastFallback(for: id) {
            attempt.result = "fallback failed as well"
            recordFallback(attempt, for: id)
        }
    }

    func lastFallback(for id: GameID) -> FallbackAttempt? {
        (try? store?.overrides.get(game: id, key: "fallback.last")).flatMap(\.self).flatMap {
            try? JSONDecoder().decode(FallbackAttempt.self, from: Data($0.utf8))
        }
    }

    private func recordFallback(_ attempt: FallbackAttempt, for id: GameID) {
        if let data = try? JSONEncoder().encode(attempt), let json = String(data: data, encoding: .utf8) {
            try? store?.overrides.set(game: id, key: "fallback.last", valueJson: json)
        }
    }
}
