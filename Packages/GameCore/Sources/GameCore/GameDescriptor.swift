import Foundation

/// One logged detection check. Lives here so `GameDescriptor` can carry evidence without depending on GameDetection.
public struct EvidenceRecord: Codable, Sendable, Hashable {
    public let check: String
    public let outcome: String
    public let weight: Double

    public init(check: String, outcome: String, weight: Double) {
        self.check = check
        self.outcome = outcome
        self.weight = weight
    }
}

/// What the library knows about one imported title. Persisted as `Games/<id>/game.json`.
/// Detection (DETECT-001) fills the engine fields; import fills identity and paths.
public struct GameDescriptor: Codable, Sendable, Hashable, Identifiable {
    public let id: GameID
    public var title: String
    /// Game root relative to `Original/` after wrapper stripping (`""` when the root is the tree root).
    public var rootRelativePath: String
    public var engine: EngineFamily
    public var generation: EngineGeneration?
    public var version: EngineVersion?
    public var runtimeCandidates: [RuntimeIdentifier]
    public var entryPoint: String?
    public var containerType: String?
    public var saveFamily: SaveFamily
    public var exportPlatform: ExportPlatform
    public var mediaRequirements: [MediaRequirement]
    public var blockers: [Blocker]
    public var warnings: [GameWarning]
    public var capabilities: [String]
    public var confidence: Double
    public var evidence: [EvidenceRecord]
    /// Stable hash of the imported payload; saves record it as provenance.
    public var identityHash: String
    public var importedAt: Date
    public var grade: PlayabilityGrade
    public var profile: CompatibilityProfile

    public init(
        id: GameID = GameID(),
        title: String,
        rootRelativePath: String = "",
        engine: EngineFamily,
        generation: EngineGeneration? = nil,
        version: EngineVersion? = nil,
        runtimeCandidates: [RuntimeIdentifier] = [],
        entryPoint: String? = nil,
        containerType: String? = nil,
        saveFamily: SaveFamily = .unknown,
        exportPlatform: ExportPlatform = .unknown,
        mediaRequirements: [MediaRequirement] = [],
        blockers: [Blocker] = [],
        warnings: [GameWarning] = [],
        capabilities: [String] = [],
        confidence: Double = 0,
        evidence: [EvidenceRecord] = [],
        identityHash: String,
        importedAt: Date = .now,
        grade: PlayabilityGrade = .loadable,
        profile: CompatibilityProfile = .init()
    ) {
        self.id = id
        self.title = title
        self.rootRelativePath = rootRelativePath
        self.engine = engine
        self.generation = generation
        self.version = version
        self.runtimeCandidates = runtimeCandidates
        self.entryPoint = entryPoint
        self.containerType = containerType
        self.saveFamily = saveFamily
        self.exportPlatform = exportPlatform
        self.mediaRequirements = mediaRequirements
        self.blockers = blockers
        self.warnings = warnings
        self.capabilities = capabilities
        self.confidence = confidence
        self.evidence = evidence
        self.identityHash = identityHash
        self.importedAt = importedAt
        self.grade = grade
        self.profile = profile
    }
}

public extension GameDescriptor {
    /// The same descriptor under another identity (a detection-time descriptor adopting the committed game id).
    func withID(_ id: GameID) -> GameDescriptor {
        GameDescriptor(
            id: id,
            title: title,
            rootRelativePath: rootRelativePath,
            engine: engine,
            generation: generation,
            version: version,
            runtimeCandidates: runtimeCandidates,
            entryPoint: entryPoint,
            containerType: containerType,
            saveFamily: saveFamily,
            exportPlatform: exportPlatform,
            mediaRequirements: mediaRequirements,
            blockers: blockers,
            warnings: warnings,
            capabilities: capabilities,
            confidence: confidence,
            evidence: evidence,
            identityHash: identityHash,
            importedAt: importedAt,
            grade: grade,
            profile: profile
        )
    }
}

/// Per-game overrides (web load mode, UA, shims, media mode, Ruby override, …). An open key/value
/// bag until the profile schema is settled by real corpus evidence.
public struct CompatibilityProfile: Codable, Sendable, Hashable {
    public var overrides: [String: String]
    public init(overrides: [String: String] = [:]) { self.overrides = overrides }
}
