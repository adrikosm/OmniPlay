import Foundation
import GameCore

public struct ExplanationSection: Sendable, Hashable, Identifiable {
    public var id: String { title }
    public let title: String
    public let lines: [String]
}

/// One runtime the player may pick when detection is not sure, with the evidence that supports it.
public struct RuntimeChoice: Sendable, Hashable, Identifiable {
    public var id: String { "\(runtime)" }
    public let runtime: RuntimeIdentifier
    public let reason: String
    public let evidence: [String]
}

/// Turns evidence into sentences a player can read, grouped by what looked, ordered by how sure it was.
public enum DetectionExplainer {
    public static func summary(_ report: DetectionReport) -> String {
        let d = report.descriptor
        var name = d.engine.rawValue
        if let v = d.version {
            name += " \(v.raw)"
        }
        switch report.outcome {
        case .supported: return "Detected \(name)."
        case let .supportedWithLimitations(l): return "Detected \(name), with \(l.count) thing\(l.count == 1 ? "" : "s") to know."
        case .experimental: return "Detected \(name); support is experimental."
        case .unknownVersion: return "Detected \(name) but not which version."
        case .unknownEngine: return "Could not tell which engine this is."
        case let .unsupported(reason): return "Cannot run this: \(reason)"
        case let .refused(r): return r.humanMessage
        }
    }

    public static func sections(_ report: DetectionReport) -> [ExplanationSection] {
        var out: [ExplanationSection] = []
        let grouped = Dictionary(grouping: report.evidence, by: \.detector)
        for id in DetectorID.allCases {
            guard let lines = grouped[id], !lines.isEmpty else { continue }
            let sorted = lines.sorted { $0.confidence > $1.confidence }.map(\.explanation)
            out.append(ExplanationSection(title: Self.title(id), lines: Array(sorted.prefix(12))))
        }
        if case let .refused(r) = report.outcome {
            out.insert(
                ExplanationSection(
                    title: "Why it cannot run",
                    lines: [r.humanMessage, r.technicalDetail] + r.alternatives.map { "Alternative: \($0)" }
                ),
                at: 0
            )
        }
        if report.candidateRuntimes.count > 1 {
            let top = report.candidateRuntimes[0], next = report.candidateRuntimes[1]
            out.append(ExplanationSection(
                title: "Why \(name(top.runtime)) and not \(name(next.runtime))",
                lines: [top.reason, "\(name(next.runtime)) stays available: \(next.reason)"]
            ))
        }
        return out
    }

    /// At most four plausible runtimes for the picker, each with the evidence lines behind it.
    public static func candidates(_ report: DetectionReport) -> [RuntimeChoice] {
        report.candidateRuntimes.prefix(4).map { c in
            RuntimeChoice(
                runtime: c.runtime,
                reason: c.reason,
                evidence: report.evidence.filter { $0.confidence >= 0.8 }.prefix(3).map(\.explanation)
            )
        }
    }

    public static func name(_ r: RuntimeIdentifier) -> String {
        switch r {
        case .web: "WebKit"
        case let .rgss(ruby): "mkxp-z (Ruby \(ruby.rawValue.dropFirst(4).map(String.init).joined(separator: ".")))"
        case let .renpy(engine): "Ren'Py \(engine.rawValue.dropFirst().map(String.init).joined(separator: "."))"
        case .easyrpg: "EasyRPG Player"
        case .scummvm: "ScummVM"
        case let .godot(bucket): "Godot \(bucket.rawValue.dropFirst().map(String.init).joined(separator: "."))"
        case .love: "LÖVE"
        case .onscripter: "ONScripter"
        case .tic80: "TIC-80"
        }
    }

    static func title(_ id: DetectorID) -> String {
        switch id {
        case .containerSniffer: "Container"
        case .structure: "Folder layout"
        case .rgss: "RPG Maker XP / VX / VX Ace"
        case .rpgMakerMVMZ: "RPG Maker MV / MZ"
        case .mvmzPlugins: "Plugins"
        case .renpy: "Ren'Py"
        case .html5Web: "Web build"
        case .rm2k3: "RPG Maker 2000 / 2003"
        case .godotPCK: "Godot"
        case .refusals: "Native engine"
        case .versionBuckets: "Runtime choice"
        case .media: "Media"
        case .saveFamily: "Saves"
        case .aggregate: "Overall"
        }
    }
}
