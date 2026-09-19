import Foundation

/// `webContentProcessDidTerminate` is not reliably called on memory kills, so a heartbeat is mandatory.
/// Pure state machine: feed it events and clock readings, act on what it returns.
public struct WebProcessWatchdog: Sendable, Equatable {
    public enum Event: Sendable, Equatable { case heartbeat, terminated, paused, resumed, pageBooted }
    public enum Action: Sendable, Equatable { case none, reloadAndAutoload(reason: String), giveUp(reason: String) }

    public static let heartbeatGap: TimeInterval = 8
    public static let maxTerminations = 3
    public static let terminationWindow: TimeInterval = 600

    public private(set) var lastHeartbeat: Date
    public private(set) var paused = false
    public private(set) var terminations: [Date] = []
    public private(set) var suspected = false

    public init(now: Date) { lastHeartbeat = now }

    public mutating func handle(_ event: Event, now: Date) -> Action {
        switch event {
        case .heartbeat, .pageBooted:
            lastHeartbeat = now
            suspected = false
            return .none
        case .paused:
            paused = true
            return .none
        case .resumed:
            paused = false
            lastHeartbeat = now
            return .none
        case .terminated:
            return record(now: now, reason: "the web content process ended")
        }
    }

    /// Call on a timer: no heartbeat for 8 s while running is a suspected termination.
    public mutating func tick(now: Date) -> Action {
        guard !paused, !suspected, now.timeIntervalSince(lastHeartbeat) > Self.heartbeatGap else { return .none }
        suspected = true
        return record(now: now, reason: "no heartbeat for \(Int(Self.heartbeatGap)) seconds")
    }

    private mutating func record(now: Date, reason: String) -> Action {
        terminations.append(now)
        terminations.removeAll { now.timeIntervalSince($0) > Self.terminationWindow }
        lastHeartbeat = now
        if terminations.count >= Self.maxTerminations {
            return .giveUp(reason: "the game's web process ended \(terminations.count) times in ten minutes")
        }
        return .reloadAndAutoload(reason: reason)
    }
}
