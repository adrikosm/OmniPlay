import GameCore

/// One logged check (design authority §17: "every check logged").
public struct DetectionEvidence: Codable, Sendable, Hashable {
    public let check: String
    public let outcome: String
    public let weight: Double

    public init(check: String, outcome: String, weight: Double) {
        self.check = check
        self.outcome = outcome
        self.weight = weight
    }
}

/// Confidence gates: ≥0.90 auto, 0.60–0.89 warn, <0.60 manual picker. Bias toward refusal on ambiguity.
public enum ConfidenceGate: Sendable, Equatable {
    case automatic
    case warn
    case manualPicker

    public init(confidence: Double) {
        switch confidence {
        case 0.90...: self = .automatic
        case 0.60 ..< 0.90: self = .warn
        default: self = .manualPicker
        }
    }
}

public struct DetectionResult: Codable, Sendable, Hashable {
    public let engine: EngineFamily
    public let engineVersion: String?
    public let confidence: Double
    public let evidence: [DetectionEvidence]

    public init(engine: EngineFamily, engineVersion: String? = nil, confidence: Double, evidence: [DetectionEvidence]) {
        self.engine = engine
        self.engineVersion = engineVersion
        self.confidence = min(max(confidence, 0), 1)
        self.evidence = evidence
    }

    public var gate: ConfidenceGate { ConfidenceGate(confidence: confidence) }
    public var isRefusal: Bool { engine.tier == .refused }
}

/// A structural signature. Signatures run in the fixed precedence of §17; the first hit wins.
public protocol DetectionSignature: Sendable {
    var name: String { get }
    func evaluate(_ tree: any GameTreeProbe) throws -> DetectionResult?
}
