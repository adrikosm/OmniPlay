import Foundation

/// Identity of one imported game; also the name of its directory under `Games/`. Encodes as a UUID string.
public struct GameID: Hashable, Sendable, CustomStringConvertible, Codable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public init?(uuidString: String) {
        guard let u = UUID(uuidString: uuidString) else { return nil }
        rawValue = u
    }

    public var description: String { rawValue.uuidString }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(UUID.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}
