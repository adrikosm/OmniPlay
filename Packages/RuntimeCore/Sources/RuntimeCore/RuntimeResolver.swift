import GameCore
import GameDetection

public enum PreparationStep: Codable, Sendable, Hashable {
    case mediaJobs(count: Int)
    case buildCaseIndex
    case installHostShims(EngineFamily)
    case writeRuntimeConfig
    case rtpCheck(String)
    case soundfontCheck
}

/// The one place a runtime gets chosen. UI shows it; UI never decides.
public struct RuntimeResolution: Codable, Sendable, Hashable {
    public var selectedRuntime: RuntimeIdentifier?
    public var selectedRuntimeVersion: String?
    public var confidence: Double
    public var reason: String
    public var flags: RuntimeCapabilityFlags
    public var requiredPreparation: [PreparationStep]
    public var warnings: [GameWarning]
    public var fallbacks: [RuntimeCandidate]
    public var slot: SessionSlot?
    public var profile: CompatibilityProfile
    public var outcome: DetectionOutcome
    public var manualOverride: Bool

    public init(
        selectedRuntime: RuntimeIdentifier?,
        selectedRuntimeVersion: String?,
        confidence: Double,
        reason: String,
        flags: RuntimeCapabilityFlags,
        requiredPreparation: [PreparationStep],
        warnings: [GameWarning],
        fallbacks: [RuntimeCandidate],
        slot: SessionSlot?,
        profile: CompatibilityProfile,
        outcome: DetectionOutcome,
        manualOverride: Bool
    ) {
        self.selectedRuntime = selectedRuntime
        self.selectedRuntimeVersion = selectedRuntimeVersion
        self.confidence = confidence
        self.reason = reason
        self.flags = flags
        self.requiredPreparation = requiredPreparation
        self.warnings = warnings
        self.fallbacks = fallbacks
        self.slot = slot
        self.profile = profile
        self.outcome = outcome
        self.manualOverride = manualOverride
    }
}

public struct RuntimeResolver: Sendable {
    public let registry: RuntimeRegistry
    public init(registry: RuntimeRegistry) { self.registry = registry }

    public func resolve(_ report: DetectionReport, override: RuntimeIdentifier? = nil) async -> RuntimeResolution {
        let d = report.descriptor
        var warnings = d.warnings
        var res = RuntimeResolution(
            selectedRuntime: nil,
            selectedRuntimeVersion: nil,
            confidence: report.confidence,
            reason: "",
            flags: [],
            requiredPreparation: [],
            warnings: warnings,
            fallbacks: [],
            slot: nil,
            profile: d.profile,
            outcome: report.outcome,
            manualOverride: false
        )
        switch report.outcome {
        case let .refused(r): res.reason = r.humanMessage; return res
        case let .unsupported(reason): res.reason = reason; return res
        default: break
        }
        var candidates = report.candidateRuntimes
        if let override {
            if await registry.descriptor(for: override) != nil {
                candidates.insert(RuntimeCandidate(runtime: override, confidence: 1, reason: "manual override"), at: 0)
                res.manualOverride = true
            } else {
                warnings.append(.note("the chosen runtime \(override) is not part of this build; automatic choice used"))
            }
        }
        var chosen: (RuntimeCandidate, RuntimeDescriptor)?
        var notBuilt: [RuntimeCandidate] = []
        for c in candidates {
            guard let desc = await registry.descriptor(for: c.runtime) else { continue }
            if desc.availability == .notBuilt {
                notBuilt.append(c); continue
            }
            chosen = (c, desc)
            break
        }
        guard let (pick, desc) = chosen else {
            res.warnings = warnings
            res.fallbacks = candidates
            if let first = candidates.first {
                res.reason = "\(first.reason); this runtime is not part of this build yet"
                res.outcome = .unsupported(reason: "no bundled runtime for \(d.engine.rawValue) yet")
                res.warnings.append(.note("runtime \(first.runtime) is planned but not built"))
            } else if report.outcome == .unknownEngine || report.outcome == .unknownVersion {
                res.reason = "detection could not choose; pick a runtime"
            } else {
                res.reason = "no runtime candidates"
                res.outcome = .unsupported(reason: "no runtime candidates for \(d.engine.rawValue)")
            }
            return res
        }
        res.selectedRuntime = pick.runtime
        res.selectedRuntimeVersion = desc.version
        res.reason = pick.reason
        res.flags = desc.flags
        res.slot = desc.slot
        res.fallbacks = candidates.filter { $0.runtime != pick.runtime }
        res.warnings = warnings + notBuilt.map { .note("preferred runtime \($0.runtime) is not built; using \(pick.runtime)") }
        res.requiredPreparation = Self.preparation(for: d, runtime: pick.runtime)
        return res
    }

    static func preparation(for d: GameDescriptor, runtime: RuntimeIdentifier) -> [PreparationStep] {
        var steps: [PreparationStep] = [.buildCaseIndex, .writeRuntimeConfig]
        let jobs = d.mediaRequirements.filter {
            if case .transcode = $0.action {
                true
            } else {
                false
            }
        }.count
        if jobs > 0 {
            steps.append(.mediaJobs(count: jobs))
        }
        if runtime == .web {
            steps.append(.installHostShims(d.engine))
        }
        for w in d.warnings {
            if case let .rtpRequired(name) = w {
                steps.append(.rtpCheck(name))
            }
            if case .soundfontRequired = w {
                steps.append(.soundfontCheck)
            }
        }
        return steps
    }
}
