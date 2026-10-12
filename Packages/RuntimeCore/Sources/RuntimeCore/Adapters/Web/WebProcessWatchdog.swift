import Foundation

/// `webContentProcessDidTerminate` is not reliably called on memory kills, so a heartbeat is mandatory. A silent page
/// is usually a busy one (a big map loading, a long save), so a short gap only asks the host to probe the process;
/// the page is reloaded when the probe finds it dead, or after a silence no busy page reaches.
/// Pure state machine: feed it events and clock readings, act on what it returns.
public struct WebProcessWatchdog: Sendable, Equatable {
    public enum Event: Sendable, Equatable { case heartbeat, terminated, paused, resumed, pageBooted }
    public enum Action: Sendable, Equatable { case none, probe, reloadAndAutoload(reason: String), giveUp(reason: String) }

    public static let heartbeatGap: TimeInterval = 8
    public static let hangLimit: TimeInterval = 45
    public static let maxTerminations = 3
    public static let terminationWindow: TimeInterval = 600

    public private(set) var lastHeartbeat: Date
    public private(set) var paused = false
    public private(set) var terminations: [Date] = []
    public private(set) var probed = false

    public init(now: Date) { lastHeartbeat = now }

    public mutating func handle(_ event: Event, now: Date) -> Action {
        switch event {
        case .heartbeat, .pageBooted:
            lastHeartbeat = now
            probed = false
            return .none
        case .paused:
            paused = true
            return .none
        case .resumed:
            paused = false
            lastHeartbeat = now
            probed = false
            return .none
        case .terminated:
            return record(now: now, reason: "the web content process ended")
        }
    }

    /// Call on a timer: 8 s of silence while running asks for a probe, 45 s is a hung page.
    public mutating func tick(now: Date) -> Action {
        guard !paused else { return .none }
        let silence = now.timeIntervalSince(lastHeartbeat)
        if silence > Self.hangLimit {
            return record(now: now, reason: "no heartbeat for \(Int(Self.hangLimit)) seconds")
        }
        guard silence > Self.heartbeatGap, !probed else { return .none }
        probed = true
        return .probe
    }

    private mutating func record(now: Date, reason: String) -> Action {
        terminations.append(now)
        terminations.removeAll { now.timeIntervalSince($0) > Self.terminationWindow }
        lastHeartbeat = now
        probed = false
        if terminations.count >= Self.maxTerminations {
            return .giveUp(reason: "the game's web process ended \(terminations.count) times in ten minutes")
        }
        return .reloadAndAutoload(reason: reason)
    }
}
