import CMkxpBridge
import Diagnostics
import Foundation
import GameCore
import RuntimeCore

/// The mkxp-z engine's own entry point, started once per app launch.
///
/// The fork's `EngineHost` is single-shot by construction: `main()` initialises SDL, ANGLE, OpenAL and one
/// Ruby VM, runs exactly one session, shuts down and returns. Ruby's `ruby_init` cannot be undone (extension
/// `Init_*` functions keep VALUEs in file-scope statics), so the VM stays alive for the process and no second
/// game can start — not even on one of the other two islanded Ruby lines, because only the line the first game
/// picked was ever initialised. `SessionSlot.diesWith` encodes that: one RGSS session spends all three slots.
///
/// The engine expects to own the main thread, and it never gives it back: `main()` returns only when the
/// session ends. It is therefore started indirectly, so `start(in:)` can return and the coordinator can reach
/// `.running` while the engine boots behind it. SDL's event pump spins CFRunLoop between frames, which is what
/// keeps UIKit drawing and main-actor work running for the rest of the session.
///
/// It has to be a **run-loop** block and not `DispatchQueue.main.async`. libdispatch guards the main queue
/// against re-entrant draining: while one main-queue block is executing, a nested `CFRunLoopRunInMode` will
/// not drain another. Hand the engine the main thread from inside a queue block and that guard stays closed
/// for the whole session — the picture renders, and every main-actor continuation in the app, the adapter's
/// own included, never runs again. A run-loop block executes outside the drain, so the queue stays live.
/// SDL's own `SDL_UIKitRunApp` reaches `SDL_main` the same way, through a zero-delay `performSelector`.
@MainActor
public enum RGSSEngineProcess {
    public enum Phase: Sendable, Equatable {
        case notStarted
        case running
        case exited(Int32)
    }

    public enum Failure: Error, Equatable {
        /// The engine objects are not in this binary (the Mac builds of the package).
        case notLinked
        /// The one boot this process gets has already happened. The app has to restart.
        case alreadySpent(Phase)
    }

    public private(set) static var phase: Phase = .notStarted

    /// True when the engine objects are linked and report a version mask, so a launch can succeed.
    public static var isLinked: Bool { omniplay_mkxp_linked() != 0 && mkxp_getSupportedRGSSVersionMask() != 0 }

    /// Which RGSS generations this build can host, as the engine itself reports them.
    public static func supports(rgssVersion: Int) -> Bool {
        (1 ... 3).contains(rgssVersion) && mkxp_getSupportedRGSSVersionMask() & (1 << (rgssVersion - 1)) != 0
    }

    /// Hands the main thread to the engine. Returns immediately; `onExit` fires on the main actor when the
    /// engine's `main()` returns, which is the end of the only session this process can host.
    public static func boot(session: SessionID?, onExit: @escaping @MainActor (Int32) -> Void) throws {
        guard isLinked else { throw Failure.notLinked }
        guard phase == .notStarted else { throw Failure.alreadySpent(phase) }
        phase = .running
        OPLog.log(.ruby, .info, "starting the mkxp-z engine on the main thread (one boot per app launch)", session: session)
        EngineMainThread.run("mkxp-z (RGSS)") {
            omniplay_mkxp_run()
        } exited: { status in
            phase = .exited(status)
            OPLog.log(.ruby, status == 0 ? .info : .error, "mkxp-z engine exited with status \(status)", session: session)
            onExit(status)
        }
    }
}
