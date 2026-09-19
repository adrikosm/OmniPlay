import GameCore

public enum DetectorID: String, Codable, Sendable, CaseIterable, Hashable {
    case containerSniffer, structure, rgss, rpgMakerMVMZ, mvmzPlugins, renpy, html5Web, rm2k3, godotPCK, refusals
    case versionBuckets, media, saveFamily, aggregate
}

public enum DetectionSource: String, Codable, Sendable, Hashable {
    case fileMagic, fileName, fileContent, directoryStructure, peHeader, sidecar, userOverride
}

public enum DetectionSignal: Codable, Sendable, Hashable {
    case present(path: String)
    case absent(path: String)
    case magic(path: String, bytes: String)
    case version(path: String, value: String)
    case count(path: String, n: Int)
    case text(path: String, excerpt: String)
}

/// One logged check. `explanation` is the sentence a player can read.
public struct DetectionEvidence: Codable, Sendable, Hashable {
    public let detector: DetectorID
    public let signal: DetectionSignal
    public let confidence: Double
    public let source: DetectionSource
    public let explanation: String

    public init(_ detector: DetectorID, _ signal: DetectionSignal, confidence: Double, source: DetectionSource, _ explanation: String) {
        self.detector = detector
        self.signal = signal
        self.confidence = confidence
        self.source = source
        self.explanation = explanation
    }

    /// The compact persisted form (`detection_results.evidence_json`, `game.json`).
    public var record: EvidenceRecord {
        EvidenceRecord(check: "\(detector.rawValue):\(signal.path)", outcome: explanation, weight: confidence)
    }
}

public extension DetectionSignal {
    var path: String {
        switch self {
        case let .present(p), let .absent(p), let .magic(p, _), let .version(p, _), let .count(p, _), let .text(p, _): p
        }
    }
}

public struct RefusalReason: Codable, Sendable, Hashable {
    public let engine: EngineFamily
    public let humanMessage: String
    public let technicalDetail: String
    public let alternatives: [String]

    public init(engine: EngineFamily, humanMessage: String, technicalDetail: String, alternatives: [String] = []) {
        self.engine = engine
        self.humanMessage = humanMessage
        self.technicalDetail = technicalDetail
        self.alternatives = alternatives
    }
}

public enum Limitation: Codable, Sendable, Hashable {
    case nodePlugins(Int), multipleEntryPoints, live2d, mediaTranscode(Int), rtpRequired, soundfont, notBuiltRuntime, other(String)
}

public enum DetectionOutcome: Codable, Sendable, Hashable {
    case supported
    case supportedWithLimitations([Limitation])
    case experimental
    case unknownVersion
    case unknownEngine
    case unsupported(reason: String)
    case refused(RefusalReason)

    public var isPlayableClass: Bool {
        switch self {
        case .supported, .supportedWithLimitations, .experimental: true
        default: false
        }
    }
}

public struct RuntimeCandidate: Codable, Sendable, Hashable {
    public let runtime: RuntimeIdentifier
    public let confidence: Double
    public let reason: String

    public init(runtime: RuntimeIdentifier, confidence: Double, reason: String) {
        self.runtime = runtime
        self.confidence = confidence
        self.reason = reason
    }
}

/// Everything detection knows about one game root, ready to persist and to explain.
public struct DetectionReport: Codable, Sendable, Hashable {
    public static let evidenceCap = 256

    public var descriptor: GameDescriptor
    public var outcome: DetectionOutcome
    public var confidence: Double
    public var evidence: [DetectionEvidence]
    public var candidateRuntimes: [RuntimeCandidate]
    public var detectorVersions: [String: Int]

    public init(
        descriptor: GameDescriptor,
        outcome: DetectionOutcome,
        confidence: Double,
        evidence: [DetectionEvidence],
        candidateRuntimes: [RuntimeCandidate],
        detectorVersions: [String: Int]
    ) {
        self.descriptor = descriptor
        self.outcome = outcome
        self.confidence = confidence
        self.evidence = Self.capped(evidence)
        self.candidateRuntimes = candidateRuntimes
        self.detectorVersions = detectorVersions
    }

    /// Keeps the first 255 lines and replaces the rest with one summary line.
    public static func capped(_ list: [DetectionEvidence]) -> [DetectionEvidence] {
        guard list.count > evidenceCap else { return list }
        let dropped = list.count - (evidenceCap - 1)
        return Array(list.prefix(evidenceCap - 1)) + [DetectionEvidence(
            .aggregate,
            .count(path: "", n: dropped),
            confidence: 0,
            source: .directoryStructure,
            "\(dropped) further evidence lines omitted"
        )]
    }
}
