import Diagnostics
import Foundation
import GameCore

/// What `stop()` reports. `.slotSpent` is a first-class, honest outcome (§4.2 rule 3).
public enum TeardownVerdict: Sendable, Equatable {
    case clean
    case slotSpent
    case restartRequired
}

public enum RuntimeStopReason: Sendable, Equatable {
    case userExit
    case switchingGame
    case memoryPressure
    case thermal
    case crash
    case hostShutdown
}

public enum PauseSemantics: Sendable, Equatable {
    /// Engine thread is suspended; audio/timers stop (mkxp-z snapshot model).
    case suspendThread
    /// Engine keeps running; the host hides it (WKWebView with page-visibility events).
    case backgroundVisible
    case unsupported
}

public struct RuntimeCapabilities: Sendable, Equatable {
    public var canInspectState: Bool
    public var canMutateState: Bool
    public var pause: PauseSemantics
    public var multiSession: Bool

    public init(canInspectState: Bool, canMutateState: Bool, pause: PauseSemantics, multiSession: Bool) {
        self.canInspectState = canInspectState
        self.canMutateState = canMutateState
        self.pause = pause
        self.multiSession = multiSession
    }
}

/// The kind of surface the shell must host for this adapter.
public enum RuntimeSurface: Sendable, Equatable {
    case webView
    case metalLayer
    case sdlWindow
}

public struct RuntimeConfiguration: Sendable {
    public var paths: AppPaths
    public var game: GameID
    public var rtpDirectory: URL?
    public var profile: CompatibilityProfile
    public var sessionID: SessionID

    public init(paths: AppPaths, game: GameID, rtpDirectory: URL? = nil, profile: CompatibilityProfile, sessionID: SessionID = .init()) {
        self.paths = paths
        self.game = game
        self.rtpDirectory = rtpDirectory
        self.profile = profile
        self.sessionID = sessionID
    }
}

/// Typed state bridge requests (§27). Engine-specific payloads are opaque here.
public struct StateInspectionRequest: Sendable, Hashable {
    public var path: String
    public init(path: String) { self.path = path }
}

public struct StateInspectionResult: Sendable, Hashable {
    public var path: String
    public var json: String
    public init(path: String, json: String) {
        self.path = path
        self.json = json
    }
}

public struct StateMutation: Sendable, Hashable {
    public var path: String
    public var json: String
    public init(path: String, json: String) {
        self.path = path
        self.json = json
    }
}

public struct StateMutationResult: Sendable, Hashable {
    public var applied: Bool
    public var message: String?
    public init(applied: Bool, message: String? = nil) {
        self.applied = applied
        self.message = message
    }
}

public enum RuntimeEvent: Sendable {
    case log(LogCategory, String)
    case gradeReached(PlayabilityGrade)
    case watchdogStalled(seconds: Double)
}

/// The shell-side object an adapter reports to. Owns the render container and the session log.
public protocol RuntimeHost: AnyObject, Sendable {
    var sessionID: SessionID { get }
    func runtimeDidEmit(_ event: RuntimeEvent)
}
