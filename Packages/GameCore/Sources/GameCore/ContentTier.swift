/// Where a byte lives. Runtimes resolve `overrides → generated → original → rtp`; the rest are host-owned.
public enum ContentTier: String, Codable, Sendable, CaseIterable, Hashable {
    case original, overrides, generated, saves, rtp, artwork, persistent, runtimeCache, importStaging
}

/// Every kind of content OmniPlay tells apart, with the one tier it lives in and who may write it.
public enum ContentKind: String, Codable, Sendable, CaseIterable, Hashable {
    case originalGame, generatedCompatibility, modOverride, translationOverride, hostShim
    case saveFile, saveBackup, persistentEngineData, runtimeCache, importTemporary

    public var ownership: ContentOwnership {
        switch self {
        case .originalGame: .init(tier: .original, writer: .importer, relativeDirectory: "", exportable: false)
        case .generatedCompatibility: .init(tier: .generated, writer: .mediaPipeline, relativeDirectory: "", exportable: false)
        case .modOverride: .init(tier: .overrides, writer: .modManager, relativeDirectory: "mods", exportable: false)
        case .translationOverride:
            .init(tier: .overrides, writer: .translationManager, relativeDirectory: "translations", exportable: false)
        case .hostShim: .init(tier: .overrides, writer: .host, relativeDirectory: "host", exportable: false)
        case .saveFile: .init(tier: .saves, writer: .runtime, relativeDirectory: "slots", exportable: true)
        case .saveBackup: .init(tier: .saves, writer: .saveManager, relativeDirectory: "backups", exportable: true)
        case .persistentEngineData: .init(tier: .persistent, writer: .runtime, relativeDirectory: "", exportable: true)
        case .runtimeCache: .init(tier: .runtimeCache, writer: .runtime, relativeDirectory: "", exportable: false)
        case .importTemporary: .init(tier: .importStaging, writer: .importer, relativeDirectory: "", exportable: false)
        }
    }
}

public struct ContentOwnership: Sendable, Hashable {
    public let tier: ContentTier
    public let writer: ContentWriter
    /// Sub-directory inside the tier root (`mods/<modID>/` gets its ID appended by the caller).
    public let relativeDirectory: String
    /// May appear in `Documents/OmniPlay/Saves-Export` for the user.
    public let exportable: Bool
    /// Game trees are excluded from device backup as a whole (§15.2); the user's export folder is not.
    public var backedUp: Bool { false }
}

public enum ContentWriter: String, Codable, Sendable, CaseIterable, Hashable {
    case importer, runtime, host, modManager, translationManager, saveManager, mediaPipeline
}
