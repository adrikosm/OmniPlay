import Foundation
import GameCore

/// Thresholds to recalibrate from the private corpus once it exists.
public enum DetectionThresholds {
    public static let automatic = 0.90
    public static let limited = 0.60
    public static let ambiguityBand = 0.15
}

/// Combines detector reports: highest family claim wins, refusal ≥ 0.9 overrides, blockers force unsupported,
/// close competing families → unknownEngine, missing version → unknownVersion. UNKNOWN never becomes "closest runtime".
public struct OutcomeAggregator: Aggregating {
    public init() {}

    public func aggregate(
        reports: [(DetectorID, DetectorReport)],
        analyzers: [any Analyzer],
        ctx: ScanContext,
        facts: StructureFacts,
        id: GameID,
        title: String,
        identityHash: String,
        rootRelativePath: String
    ) -> DetectionReport {
        var evidence: [DetectionEvidence] = []
        var partial = PartialDescriptor()
        var claims: [(EngineFamily, Double)] = []
        var refusal: RefusalReason?
        var unsupported: String?
        for (_, r) in reports {
            evidence += r.evidence
            if let c = r.claim {
                claims.append(c)
            }
            if let ref = r.refusal, refusal == nil || ref.engine == partial.engine {
                refusal = ref
            }
            if let u = r.unsupported, unsupported == nil {
                unsupported = u
            }
            partial.merge(r.partial)
        }
        claims.sort { $0.1 > $1.1 }
        let top = claims.first
        let family = top?.0 ?? .unknown
        var confidence = top?.1 ?? 0
        partial.engine = top?.0
        if top != nil, refusal == nil, unsupported == nil {
            for analyzer in analyzers {
                analyzer.analyze(ctx, facts: facts, partial: &partial, evidence: &evidence)
            }
        }
        let runnerUp = claims.dropFirst().first { $0.0 != family }

        let outcome: DetectionOutcome
        if let refusal, refusal.engine == family || confidence < DetectionThresholds.automatic {
            outcome = .refused(refusal)
            confidence = max(confidence, DetectionThresholds.automatic)
        } else if let unsupported {
            outcome = .unsupported(reason: unsupported)
        } else if !partial.blockers.isEmpty {
            outcome = .unsupported(reason: partial.blockers.map(Self.describe).joined(separator: "; "))
        } else if top == nil || confidence < DetectionThresholds.limited {
            outcome = .unknownEngine
        } else if let runnerUp, confidence - runnerUp.1 < DetectionThresholds.ambiguityBand {
            outcome = .unknownEngine
            evidence.append(DetectionEvidence(
                .aggregate,
                .text(path: "", excerpt: "\(family.rawValue) vs \(runnerUp.0.rawValue)"),
                confidence: confidence,
                source: .directoryStructure,
                "Two engines score alike: \(family.rawValue) and \(runnerUp.0.rawValue)"
            ))
        } else if Self.needsVersion(family), partial.generation == nil, partial.version == nil {
            outcome = .unknownVersion
        } else if family == .html5, partial.profileHints["webSubFamily"] == nil {
            outcome = .experimental
        } else if confidence < DetectionThresholds.automatic || !partial.warnings.isEmpty {
            outcome = .supportedWithLimitations(Self.limitations(
                from: partial.warnings,
                lowConfidence: confidence < DetectionThresholds.automatic
            ))
        } else {
            outcome = .supported
        }

        let grade: PlayabilityGrade = outcome.isPlayableClass ? .loadable : .refused
        let descriptor = GameDescriptor(
            id: id, title: partial.title ?? title, rootRelativePath: rootRelativePath, engine: family, generation: partial.generation,
            version: partial.version, runtimeCandidates: partial.runtimeCandidates.map(\.runtime), entryPoint: partial.entryPoint,
            saveFamily: partial.saveFamily ?? .unknown, exportPlatform: partial.exportPlatform ?? .unknown,
            mediaRequirements: partial.mediaRequirements, blockers: partial.blockers, warnings: partial.warnings,
            capabilities: partial.profileHints.map { "\($0.key)=\($0.value)" }.sorted(), confidence: confidence,
            evidence: evidence.map(\.record), identityHash: identityHash, grade: grade,
            profile: CompatibilityProfile(overrides: partial.profileHints)
        )
        return DetectionReport(
            descriptor: descriptor,
            outcome: outcome,
            confidence: confidence,
            evidence: evidence,
            candidateRuntimes: partial.runtimeCandidates,
            detectorVersions: [:]
        )
    }

    static func needsVersion(_ family: EngineFamily) -> Bool {
        [.rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce, .renpy, .godot].contains(family)
    }

    static func limitations(from warnings: [GameWarning], lowConfidence: Bool) -> [Limitation] {
        var out: [Limitation] = lowConfidence ? [.other("detection confidence below automatic threshold")] : []
        var node = 0, transcode = 0
        for w in warnings {
            switch w {
            case .nodePlugin: node += 1
            case .multipleEntryPoints: out.append(.multipleEntryPoints)
            case .live2dRequiresLicensedCore: out.append(.live2d)
            case let .mediaTranscodeRequired(n): transcode += n
            case .rtpRequired: out.append(.rtpRequired)
            case .soundfontRequired: out.append(.soundfont)
            case let .unknownVersion(v): out.append(.other("unknown version \(v)"))
            case .note: break
            }
        }
        if node > 0 {
            out.append(.nodePlugins(node))
        }
        if transcode > 0 {
            out.append(.mediaTranscode(transcode))
        }
        return out
    }

    static func describe(_ b: Blocker) -> String {
        switch b {
        case let .nativeBinary(p): "native binary \(p)"
        case let .gdextension(n): "GDExtension libraries: \(n.joined(separator: ", "))"
        case .encryptedPCK: "encrypted Godot package"
        case .csharpExport: "C# (Mono) Godot export"
        case let .nodePlugin(f, api): "plugin \(f) needs \(api)"
        }
    }
}

extension PartialDescriptor {
    /// Later detectors fill gaps; the first non-nil value wins for scalars, lists concatenate.
    mutating func merge(_ other: PartialDescriptor) {
        engine = engine ?? other.engine
        generation = generation ?? other.generation
        version = version ?? other.version
        entryPoint = entryPoint ?? other.entryPoint
        exportPlatform = exportPlatform ?? other.exportPlatform
        saveFamily = saveFamily ?? other.saveFamily
        title = title ?? other.title
        runtimeCandidates += other.runtimeCandidates
        blockers += other.blockers
        warnings += other.warnings
        mediaRequirements += other.mediaRequirements
        for (k, v) in other.profileHints where profileHints[k] == nil {
            profileHints[k] = v
        }
    }
}

public extension DetectionReport {
    /// A plugin that mentions `child_process` or a native `.node` addon used to refuse the whole game; it is a named
    /// warning now (`MVMZPluginScanner`). A report stored before that reads as if detected today, so games imported
    /// then play without being imported again. Any other refusal stays as it was.
    func liftingPluginBlockers() -> DetectionReport {
        let blockers = descriptor.blockers
        let kept = blockers.filter {
            if case .nodePlugin = $0 {
                false
            } else {
                true
            }
        }
        guard kept.count != blockers.count, case let .unsupported(reason) = outcome,
              reason == blockers.map(OutcomeAggregator.describe).joined(separator: "; ") else { return self }
        var report = self
        report.descriptor.blockers = kept
        let d = report.descriptor
        if !kept.isEmpty {
            report.outcome = .unsupported(reason: kept.map(OutcomeAggregator.describe).joined(separator: "; "))
        } else if confidence < DetectionThresholds.limited {
            report.outcome = .unknownEngine
        } else if OutcomeAggregator.needsVersion(d.engine), d.generation == nil, d.version == nil {
            report.outcome = .unknownVersion
        } else if d.engine == .html5, d.profile.overrides["webSubFamily"] == nil {
            report.outcome = .experimental
        } else if confidence < DetectionThresholds.automatic || !d.warnings.isEmpty {
            report.outcome = .supportedWithLimitations(OutcomeAggregator.limitations(
                from: d.warnings,
                lowConfidence: confidence < DetectionThresholds.automatic
            ))
        } else {
            report.outcome = .supported
        }
        report.descriptor.grade = report.outcome.isPlayableClass ? .loadable : .refused
        return report
    }
}
