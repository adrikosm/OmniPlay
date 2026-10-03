import Diagnostics
import Foundation
import GameCore

/// Runs the registered detectors in fixed precedence, then the aggregator. Refusals are recorded first but the
/// family detectors still run so the evidence is complete. A throwing detector becomes an evidence line.
public struct DetectionPipeline: Sendable {
    public let detectors: [any Detector]
    public let analyzers: [any Analyzer]

    public init(detectors: [any Detector], analyzers: [any Analyzer] = []) {
        self.detectors = detectors
        self.analyzers = analyzers
    }

    public func run(
        _ ctx: ScanContext,
        id: GameID = GameID(),
        title: String,
        identityHash: String,
        rootRelativePath: String = ""
    ) -> DetectionReport {
        let facts = StructureFacts.inspect(ctx)
        var reports: [(DetectorID, DetectorReport)] = []
        var versions: [String: Int] = [:]
        var failures: [DetectionEvidence] = []
        for detector in detectors {
            versions[detector.id.rawValue] = detector.version
            do {
                try reports.append((detector.id, detector.probe(ctx, facts: facts)))
            } catch {
                failures.append(DetectionEvidence(
                    detector.id,
                    .text(path: "", excerpt: String(describing: error)),
                    confidence: 0,
                    source: .directoryStructure,
                    "\(detector.id.rawValue) failed: \(error)"
                ))
                OPLog.log(.detection, .error, "detector \(detector.id.rawValue) failed: \(error)")
            }
        }
        for analyzer in analyzers {
            versions[analyzer.id.rawValue] = analyzer.version
        }
        var report = OutcomeAggregator().aggregate(
            reports: reports, analyzers: analyzers, ctx: ctx, facts: facts, id: id, title: title, identityHash: identityHash,
            rootRelativePath: rootRelativePath
        )
        report.evidence = DetectionReport.capped(report.evidence + failures)
        report.detectorVersions = versions
        OPLog.log(.detection, .info, "\(title): \(report.descriptor.engine.rawValue) \(report.outcome) confidence \(report.confidence)")
        return report
    }
}
