import GameCore

/// Partial descriptor fields a detector contributes; the aggregator merges them.
public struct PartialDescriptor: Sendable, Hashable {
    public var engine: EngineFamily?
    public var generation: EngineGeneration?
    public var version: EngineVersion?
    public var entryPoint: String?
    public var exportPlatform: ExportPlatform?
    public var saveFamily: SaveFamily?
    public var title: String?
    public var runtimeCandidates: [RuntimeCandidate] = []
    public var blockers: [Blocker] = []
    public var warnings: [GameWarning] = []
    public var profileHints: [String: String] = [:]
    public var mediaRequirements: [MediaRequirement] = []
    public init() {}
}

public struct DetectorReport: Sendable {
    public var evidence: [DetectionEvidence] = []
    var claim: (family: EngineFamily, confidence: Double)?
    public var refusal: RefusalReason?
    public var unsupported: String?
    public var partial = PartialDescriptor()

    public init() {}

    public mutating func claimFamily(_ family: EngineFamily, _ confidence: Double) {
        if claim == nil || confidence > claim!.confidence {
            claim = (family, confidence)
        }
        partial.engine = family
    }

    public mutating func add(
        _ detector: DetectorID,
        _ signal: DetectionSignal,
        _ confidence: Double,
        _ source: DetectionSource,
        _ explanation: String
    ) {
        evidence.append(DetectionEvidence(detector, signal, confidence: confidence, source: source, explanation))
    }
}

/// One family or analysis detector. Deterministic: sorted listings, no clocks, no randomness.
public protocol Detector: Sendable {
    var id: DetectorID { get }
    var version: Int { get }
    func probe(_ ctx: ScanContext, facts: StructureFacts) throws -> DetectorReport
}
