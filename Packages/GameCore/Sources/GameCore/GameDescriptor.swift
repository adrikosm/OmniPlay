import Foundation

/// What the library knows about one imported title. Persisted as `Games/<UUID>/game.json`.
public struct GameDescriptor: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var title: String
    public var engine: EngineFamily
    public var engineVersion: String?
    /// Stable hash of the imported payload; saves record it as provenance (§15.1).
    public var identityHash: String
    public var importedAt: Date
    public var grade: PlayabilityGrade
    public var profile: CompatibilityProfile

    public init(
        id: UUID = UUID(),
        title: String,
        engine: EngineFamily,
        engineVersion: String? = nil,
        identityHash: String,
        importedAt: Date = .now,
        grade: PlayabilityGrade = .loadable,
        profile: CompatibilityProfile = .init()
    ) {
        self.id = id
        self.title = title
        self.engine = engine
        self.engineVersion = engineVersion
        self.identityHash = identityHash
        self.importedAt = importedAt
        self.grade = grade
        self.profile = profile
    }
}

/// Per-game overrides (web load mode, UA, shims, media mode, Ruby override, …) — design authority Phase 5.
/// Kept as an open key/value bag until the profile schema is settled by real corpus evidence.
public struct CompatibilityProfile: Codable, Sendable, Hashable {
    public var overrides: [String: String]

    public init(overrides: [String: String] = [:]) {
        self.overrides = overrides
    }
}
