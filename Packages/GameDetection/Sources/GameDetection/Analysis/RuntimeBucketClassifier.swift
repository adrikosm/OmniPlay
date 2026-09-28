import GameCore

/// Maps generation and version to concrete runtimes. Pure rules from the architecture tables:
/// Ren'Py Py2 → 7.8.7 then 8.5.3; Py3.9 → 8.3.7 then 8.5.3; Py3.12 → 8.5.3. RGSS and Godot detectors already
/// name their runtime; this stage checks them and explains the mapping.
public struct RuntimeBucketClassifier: Analyzer {
    public let id = DetectorID.versionBuckets
    public let version = 1
    public init() {}

    public func analyze(_ ctx: ScanContext, facts: StructureFacts, partial: inout PartialDescriptor, evidence: inout [DetectionEvidence]) {
        guard let engine = partial.engine else { return }
        switch engine {
        case .renpy:
            let v = partial.version
            let newer = v.map { $0 > EngineVersion(major: 8, minor: 5, patch: 3) } ?? false
            switch partial.generation {
            case .renpyPy27?:
                partial.runtimeCandidates = [
                    .init(runtime: .renpy(engine: .v787), confidence: 0.95, reason: "Python 2 title; Ren'Py 7.8.7 is its native engine"),
                    .init(runtime: .renpy(engine: .v853), confidence: 0.5, reason: "Ren'Py 8.5.3 in script-compatibility mode"),
                ]
            case .renpyPy39?:
                partial.runtimeCandidates = [
                    .init(runtime: .renpy(engine: .v837), confidence: 0.95, reason: "Python 3.9 title; Ren'Py 8.3.7 matches"),
                    .init(runtime: .renpy(engine: .v853), confidence: 0.6, reason: "Ren'Py 8.5.3 as the newer fallback"),
                ]
            case .renpyPy312?:
                partial.runtimeCandidates = [.init(
                    runtime: .renpy(engine: .v853),
                    confidence: newer ? 0.6 : 0.95,
                    reason: newer ? "newer than 8.5.3; running on 8.5.3" : "Python 3.12 title; Ren'Py 8.5.3 matches"
                )]
            default:
                partial.runtimeCandidates = []
            }
            if newer, let v {
                partial.warnings.append(.unknownVersion(v.raw))
            }
        case .rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce, .godot, .kirikiri:
            break // detectors set candidates from their own evidence
        case .rpgMakerMV, .rpgMakerMZ, .html5, .unityWeb, .godotWeb, .flash:
            if partial.runtimeCandidates.isEmpty {
                partial.runtimeCandidates = [.init(
                    runtime: .web,
                    confidence: 0.9,
                    reason: "web content runs in WebKit"
                )]
            }
        case .rpgMaker2000, .rpgMaker2003:
            if partial.runtimeCandidates.isEmpty {
                partial.runtimeCandidates = [.init(
                    runtime: .easyrpg,
                    confidence: 0.9,
                    reason: "EasyRPG Player"
                )]
            }
        case .scummvm:
            partial.runtimeCandidates = [.init(runtime: .scummvm, confidence: 0.9, reason: "ScummVM")]
        default:
            partial.runtimeCandidates = []
        }
        if let first = partial.runtimeCandidates.first {
            evidence.append(DetectionEvidence(
                id,
                .text(path: "", excerpt: "\(first.runtime)"),
                confidence: first.confidence,
                source: .directoryStructure,
                "Runtime: \(first.reason)"
            ))
        }
    }
}
