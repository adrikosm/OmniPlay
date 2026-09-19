import GameCore

/// Second phase: runs after the family detectors on the merged partial descriptor.
public protocol Analyzer: Sendable {
    var id: DetectorID { get }
    var version: Int { get }
    func analyze(_ ctx: ScanContext, facts: StructureFacts, partial: inout PartialDescriptor, evidence: inout [DetectionEvidence])
}
