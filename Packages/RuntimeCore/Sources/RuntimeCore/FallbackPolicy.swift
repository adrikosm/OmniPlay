import GameCore
import GameDetection

/// Why a session ended badly, as far as the fallback decision cares.
public enum FailureCategory: String, Sendable, Codable {
    /// The engine rejected the game's content at boot (a script error, a version it will not load).
    case engineRefusedContent
    /// The runtime lacks something the game needs.
    case missingRuntimeFeature
    /// The engine died while starting.
    case crashAtBoot
    case crashInPlay
    case memoryKill
    case hang
    case userExit

    /// Failures another engine of the same family might not have. A crash mid-play, a memory kill or a hang is the
    /// game or the device, and changing engines behind the player's back would hide it.
    public var mayFallBack: Bool {
        switch self {
        case .engineRefusedContent, .missingRuntimeFeature, .crashAtBoot: true
        case .crashInPlay, .memoryKill, .hang, .userExit: false
        }
    }
}

/// One automatic retry on a sibling runtime, never more: only for failures at boot (within `bootWindow` of the
/// start), only to a candidate of the same family that this build has and whose slot is free, and only once per game
/// per app launch. The caller records the attempt, and keeps the candidate as the game's runtime if it then plays.
public enum FallbackPolicy {
    public static let bootWindow: Duration = .seconds(30)

    public static func decide(
        failure: FailureCategory,
        elapsed: Duration,
        resolution: RuntimeResolution,
        alreadyTried: Bool,
        available: (RuntimeIdentifier) -> Bool,
        slotFree: (SessionSlot) -> Bool
    ) -> RuntimeCandidate? {
        guard failure.mayFallBack, elapsed <= bootWindow, !alreadyTried, !resolution.manualOverride,
              let selected = resolution.selectedRuntime else { return nil }
        return resolution.fallbacks.first { candidate in
            candidate.runtime != selected && sameFamily(candidate.runtime, selected)
                && available(candidate.runtime) && slotFree(candidate.runtime.slot)
        }
    }

    /// Engines that read the same game data: Ren'Py versions, Ruby lines of mkxp-z, Godot buckets.
    static func sameFamily(_ a: RuntimeIdentifier, _ b: RuntimeIdentifier) -> Bool {
        switch (a, b) {
        case (.renpy, .renpy), (.rgss, .rgss), (.godot, .godot): true
        default: false
        }
    }
}
