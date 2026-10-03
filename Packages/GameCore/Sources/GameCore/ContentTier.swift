/// Where a byte lives. Runtimes resolve `overrides → generated → original → rtp`; the rest are host-owned.
public enum ContentTier: String, Codable, Sendable, CaseIterable, Hashable {
    case original, overrides, generated, saves, rtp, artwork, persistent, runtimeCache, importStaging
}

/// Every kind of content OmniPlay tells apart, with the one tier it lives in.
public enum ContentKind: String, Codable, Sendable, CaseIterable, Hashable {
    case originalGame, generatedCompatibility, modOverride, translationOverride, hostShim
    case saveFile, saveBackup, persistentEngineData, runtimeCache, importTemporary

    public var ownership: ContentOwnership {
        switch self {
        case .originalGame: .init(tier: .original, relativeDirectory: "")
        case .generatedCompatibility: .init(tier: .generated, relativeDirectory: "")
        case .modOverride: .init(tier: .overrides, relativeDirectory: "mods")
        case .translationOverride: .init(tier: .overrides, relativeDirectory: "translations")
        case .hostShim: .init(tier: .overrides, relativeDirectory: "host")
        case .saveFile: .init(tier: .saves, relativeDirectory: "slots")
        case .saveBackup: .init(tier: .saves, relativeDirectory: "backups")
        case .persistentEngineData: .init(tier: .persistent, relativeDirectory: "")
        case .runtimeCache: .init(tier: .runtimeCache, relativeDirectory: "")
        case .importTemporary: .init(tier: .importStaging, relativeDirectory: "")
        }
    }
}

public struct ContentOwnership: Sendable, Hashable {
    public let tier: ContentTier
    /// Sub-directory inside the tier root (`mods/<modID>/` gets its ID appended by the caller).
    public let relativeDirectory: String
}
