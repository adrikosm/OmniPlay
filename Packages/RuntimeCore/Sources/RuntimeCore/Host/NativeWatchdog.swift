import Diagnostics
import Foundation
import GameCore

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
    /// Running this long without a first frame is a hang too, not a slow load; a cold RGSS boot measured about 11 s.
    public static let firstFrameLimit: Double = 30

    private let read: @MainActor () -> Reading
    private let onStall: @MainActor (Double) -> Void
    private var task: Task<Void, Never>?
    private var stalledSince: Date?
    /// Nothing counts as a stall until the engine has drawn once. Loading a game legitimately takes seconds at
    /// zero frames a second, and a watchdog that cannot tell that from a hang is worse than none.
    private var hasDrawn = false
    /// Unpaused, foreground seconds spent waiting for that first frame.
    private var waitedForFirstFrame = 0.0

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

    /// The shared stall report: the stall event, a log line, and past `hangLimit` the player-facing failure.
    public static func report(
        _ stalled: Double,
        engine: String,
        category: LogCategory = .runtime,
        host: (any RuntimeHost)?,
        session: SessionID?,
        onFailure: (@MainActor (String) -> Void)?
    ) {
        host?.runtimeDidEmit(.watchdogStalled(seconds: stalled))
        OPLog.log(category, .error, "\(engine) unresponsive for \(Int(stalled))s", session: session)
        if stalled >= hangLimit {
            onFailure?("The game stopped responding. Leaving the game will need OmniPlay to restart.")
        }
    }

    private func tick() {
        let reading = read()
        guard !reading.terminated else { stop(); return }
        // Read even while the app is inactive, so the next sample measures from now: an engine in the background
        // or under Control Center draws nothing on purpose.
        guard !reading.paused, Self.appActive else { stalledSince = nil; return }
        if reading.framesPerSecond >= Self.stallFPS {
            hasDrawn = true
        } else if !hasDrawn {
            waitedForFirstFrame += Self.interval / .seconds(1)
        }
        let stuck = reading.hung || reading.framesPerSecond < Self.stallFPS && (hasDrawn || waitedForFirstFrame >= Self.firstFrameLimit)
        guard stuck else { stalledSince = nil; return }
        let since = stalledSince ?? Date()
        stalledSince = since
        onStall(Date().timeIntervalSince(since))
    }
}

private extension NativeWatchdog {
    static var appActive: Bool {
        #if canImport(UIKit)
            UIApplication.shared.applicationState == .active
        #else
            true
        #endif
    }
}

/// Frames per second from a running frame counter read at intervals (`&-` survives the counter wrapping).
public struct FrameRateSampler {
    private var frames: UInt
    private var at = ContinuousClock.now

    /// Measures from now and from `frames`.
    public init(frames: UInt = 0) { self.frames = frames }

    public mutating func sample(_ frames: UInt) -> Double {
        let now = ContinuousClock.now, elapsed = (now - at) / .seconds(1)
        let fps = elapsed > 0 ? Double(frames &- self.frames) / elapsed : 0
        (self.frames, at) = (frames, now)
        return fps
    }
}

#if canImport(UIKit)
    import UIKit

    // Shared by the native engine adapters (EasyRPG, Godot, Ren'Py, ScummVM).

    public extension RuntimeHost {
        /// Contract rule 9: hands the overlay back and takes the engine's own window down with the session.
        func releaseEngineWindow(_ window: UIWindow?) {
            releaseEngineWindow()
            window?.isHidden = true
            window?.windowScene = nil
        }
    }

    /// SDL-style app lifecycle codes for native engines, which hear nothing from an app delegate that is not theirs:
    /// 0 will resign active, 1 did enter background, 2 will enter foreground, 3 did become active, and with
    /// `memoryWarning` 4 for a memory warning. Remove the returned observers in `stop`.
    public enum EngineAppEvents {
        @MainActor
        public static func observe(
            memoryWarning: Bool = false,
            _ forward: @escaping @MainActor @Sendable (Int32) -> Void
        ) -> [NSObjectProtocol] {
            var events: [(Notification.Name, Int32)] = [
                (UIApplication.willResignActiveNotification, 0),
                (UIApplication.didEnterBackgroundNotification, 1),
                (UIApplication.willEnterForegroundNotification, 2),
                (UIApplication.didBecomeActiveNotification, 3),
            ]
            if memoryWarning {
                events.append((UIApplication.didReceiveMemoryWarningNotification, 4))
            }
            return events.map { name, event in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { forward(event) }
                }
            }
        }
    }

    public extension UIView {
        /// The view as last drawn, for the frozen frame; nil before it has a size.
        func frozenFrame() -> CGImage? {
            guard bounds.width > 0 else { return nil }
            return UIGraphicsImageRenderer(bounds: bounds).image { _ in
                drawHierarchy(in: bounds, afterScreenUpdates: false)
            }.cgImage
        }
    }

    public extension CGImage {
        /// A frame an engine wrote to disk; the file is deleted once read.
        static func takeFrame(at url: URL) -> CGImage? {
            guard let image = UIImage(contentsOfFile: url.path(percentEncoded: false)) else { return nil }
            try? FileManager.default.removeItem(at: url)
            return image.cgImage
        }
    }
#endif
