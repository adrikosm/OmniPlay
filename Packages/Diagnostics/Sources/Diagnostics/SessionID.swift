import Foundation

/// Identifies one runtime session. Log directories are `Logs/<gameUUID>/<sessionUUID>/` (§15.2).
public struct SessionID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}
