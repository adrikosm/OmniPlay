import Foundation

/// Watches a native engine for the one failure a shared-process runtime can inflict on the whole app: engine or
/// script code that never returns. An engine thread cannot be killed from outside, so the watchdog's job is not
/// recovery but honesty: tell the player the game is stuck and that leaving it costs a restart.
///
/// Each adapter supplies a `Reading` of what its engine publishes: whether it has ended, whether it is paused on
/// purpose, its own hang flag if it has one, and its frame rate, which falls to zero while the engine is blocked.
@MainActor
public final class NativeWatchdog {
    public struct Reading: Sendable {
        public var terminated: Bool
        /// Paused on purpose (or about to be): a stopped engine is not a stuck one.
        public var paused: Bool
        /// The engine's own hang flag, trusted from the start. False for engines without one.
        public var hung: Bool
        public var framesPerSecond: Double

        public init(terminated: Bool, paused: Bool, hung: Bool = false, framesPerSecond: Double) {
            self.terminated = terminated
            self.paused = paused
            self.hung = hung
            self.framesPerSecond = framesPerSecond
        }
    }

    /// Frames below this over a whole interval count as stalled; a game may legitimately draw slowly.
    public static let stallFPS = 0.5
    public static let interval: Duration = .seconds(2)
    /// Stalled for this long and the session is treated as hung rather than slow.
    public static let hangLimit: Double = 10

    private let read: @MainActor () -> Reading
    private let onStall: @MainActor (Double) -> Void
    private var task: Task<Void, Never>?
    private var stalledSince: Date?
    /// Nothing counts as a stall until the engine has drawn once. Loading a game legitimately takes seconds at
    /// zero frames a second, and a watchdog that cannot tell that from a hang is worse than none.
    private var hasDrawn = false

    /// `onStall` receives how long the engine has been stuck, every interval while it stays stuck.
    public init(read: @escaping @MainActor () -> Reading, onStall: @escaping @MainActor (Double) -> Void) {
        self.read = read
        self.onStall = onStall
    }

    public func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: NativeWatchdog.interval) } catch { return }
                guard let self else { return }
                tick()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        stalledSince = nil
    }

    private func tick() {
        let reading = read()
        guard !reading.terminated else { stop(); return }
        guard !reading.paused else { stalledSince = nil; return }
        if reading.framesPerSecond >= Self.stallFPS {
            hasDrawn = true
        }
        let stuck = reading.hung || (hasDrawn && reading.framesPerSecond < Self.stallFPS)
        guard stuck else { stalledSince = nil; return }
        let since = stalledSince ?? Date()
        stalledSince = since
        onStall(Date().timeIntervalSince(since))
    }
}
