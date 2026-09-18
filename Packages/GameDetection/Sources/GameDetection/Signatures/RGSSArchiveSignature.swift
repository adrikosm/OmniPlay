import Foundation
import GameCore

/// `"RGSSAD\0"` + version byte: 1 → `.rgssad` (XP) / `.rgss2a` (VX); 3 → `.rgss3a` (VX Ace).
/// One 8-byte read. This is §17 step 1 and the strongest RGSS signal there is.
public struct RGSSArchiveHeader: Sendable, Equatable {
    public enum Version: UInt8, Sendable {
        case v1 = 1
        case v3 = 3
    }

    public static let magic = Data("RGSSAD".utf8) + Data([0])
    public static let length = 8

    public let version: Version

    public init?(prefix: Data) {
        guard prefix.count >= Self.length, prefix.prefix(Self.magic.count) == Self.magic else { return nil }
        let versionByte = prefix[prefix.index(prefix.startIndex, offsetBy: Self.magic.count)]
        guard let version = Version(rawValue: versionByte) else { return nil }
        self.version = version
    }

    /// The engine implied by header version + archive extension, or nil when they disagree.
    public func engine(forFileExtension ext: String) -> EngineFamily? {
        switch (version, ext.lowercased()) {
        case (.v1, "rgssad"): .rpgMakerXP
        case (.v1, "rgss2a"): .rpgMakerVX
        case (.v3, "rgss3a"): .rpgMakerVXAce
        default: nil
        }
    }

    /// Best guess from the header alone (v1 is ambiguous between XP and VX).
    public var fallbackEngine: EngineFamily {
        switch version {
        case .v1: .rpgMakerXP
        case .v3: .rpgMakerVXAce
        }
    }
}

public struct RGSSArchiveSignature: DetectionSignature {
    public static let archiveExtensions = ["rgssad", "rgss2a", "rgss3a"]

    public let name = "rgss-archive-magic"

    public init() {}

    public func evaluate(_ tree: any GameTreeProbe) throws -> DetectionResult? {
        let candidates = Self.archiveExtensions.flatMap(tree.paths(withExtension:)).sorted()
        var evidence: [DetectionEvidence] = []

        for path in candidates {
            guard let prefix = try tree.readPrefix(of: path, maxBytes: RGSSArchiveHeader.length) else { continue }
            guard let header = RGSSArchiveHeader(prefix: prefix) else {
                evidence.append(.init(check: "\(name):\(path)", outcome: "extension matches, magic absent", weight: 0))
                continue
            }
            let ext = (path as NSString).pathExtension
            if let engine = header.engine(forFileExtension: ext) {
                evidence.append(.init(
                    check: "\(name):\(path)",
                    outcome: "magic v\(header.version.rawValue) matches .\(ext)",
                    weight: 0.98
                ))
                return DetectionResult(engine: engine, confidence: 0.98, evidence: evidence)
            }
            evidence.append(.init(
                check: "\(name):\(path)",
                outcome: "magic v\(header.version.rawValue) disagrees with .\(ext); using header",
                weight: 0.70
            ))
            return DetectionResult(engine: header.fallbackEngine, confidence: 0.70, evidence: evidence)
        }
        return nil
    }
}
