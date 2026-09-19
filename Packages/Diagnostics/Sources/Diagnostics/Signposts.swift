import Foundation
import OSLog

/// Named intervals for Instruments (Time Profiler, Hangs): one signposter per subsystem area.
/// Callers keep the returned state and end it when the phase changes.
public enum Signposts {
    public static let importer = OSSignposter(subsystem: "com.omniplay", category: "import")
    public static let runtime = OSSignposter(subsystem: "com.omniplay", category: "runtime")
}

/// Holds at most one open interval and closes it when the next one begins, so phase transitions map 1:1.
public struct SignpostPhase: Sendable {
    private let signposter: OSSignposter
    private var open: (StaticString, OSSignpostIntervalState)?

    public init(_ signposter: OSSignposter) { self.signposter = signposter }

    public mutating func enter(_ name: StaticString, _ detail: String = "") {
        end()
        guard signposter.isEnabled else { return }
        let id = signposter.makeSignpostID()
        open = (name, signposter.beginInterval(name, id: id, "\(detail, privacy: .public)"))
    }

    public mutating func end() {
        if let (name, state) = open {
            signposter.endInterval(name, state)
        }
        open = nil
    }
}
