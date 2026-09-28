import Foundation
import GameCore
import MediaCompat
import OverlayVFS

/// Reports what each media file needs before the chosen runtime can play it, by `MediaRules`: the conversions the
/// app then runs before first launch (`MediaPreparation`), a playable sibling already shipped, or the MV `.ogg` shim.
/// MIDI for RGSS and EasyRPG raises the soundfont warning.
public struct MediaRequirementAnalyzer: Analyzer {
    public let id = DetectorID.media
    public let version = 2
    public static let fileCap = 2000
    public init() {}

    public func analyze(_ ctx: ScanContext, facts: StructureFacts, partial: inout PartialDescriptor, evidence: inout [DetectionEvidence]) {
        guard let runtime = partial.runtimeCandidates.first?.runtime else { return }
        var patterns = ["movies/*", "www/movies/*", "audio/*/*", "www/audio/*/*", "game/*", "game/*/*", "audio/*", "movies/*/*"]
        if case .rgss = runtime {
            patterns += ["graphics/*/*.webp", "graphics/*/*.avif", "graphics/*/*.heic", "graphics/*/*.tif", "graphics/*/*.tiff"]
        }
        var seen = Set<String>()
        var files: [IndexedEntry] = []
        for p in patterns where files.count < Self.fileCap {
            for e in ctx.glob(p, limit: Self.fileCap) where !e.isDir && !seen.contains(e.key) && Self.isMedia(e.key) {
                seen.insert(e.key)
                files.append(e)
                if files.count >= Self.fileCap {
                    break
                }
            }
        }
        var transcodes = 0
        var midi = false
        for e in files {
            guard let url = ctx.url(e.realRel) else { continue }
            // Images are judged by name, but for WebP, whose header says whether it is animated.
            let info = MediaRules.kind(of: e.realRel) == .image && MediaRules.pathExtension(e.realRel) != "webp"
                ? MediaProbeResult(path: e.realRel, container: .unknown, video: nil, audio: nil)
                : MediaProbe.probe(url, relativePath: e.realRel)
            if info.container == .midi {
                midi = true
            }
            guard let action = Self.action(for: info, runtime: runtime, ctx: ctx) else { continue }
            if case .transcode = action {
                transcodes += 1
            }
            partial.mediaRequirements.append(MediaRequirement(
                sourceRel: e.realRel,
                container: info.container.rawValue,
                videoCodec: info.video?.rawValue,
                audioCodec: info.audio?.rawValue,
                requiredForRuntime: runtime,
                action: action
            ))
        }
        if transcodes > 0 {
            partial.warnings.append(.mediaTranscodeRequired(count: transcodes))
        }
        if midi,
           [.easyrpg]
           .contains(runtime) || {
               if case .rgss = runtime {
                   true
               } else {
                   false
               }
           }() { partial.warnings.append(.soundfontRequired) }
        if files.count >= Self
            .fileCap {
            partial.warnings.append(.note("more than \(Self.fileCap) media files; only the first were analysed"))
        }
        evidence.append(DetectionEvidence(
            id,
            .count(path: "media", n: files.count),
            confidence: 0.6,
            source: .directoryStructure,
            "\(files.count) media files checked, \(transcodes) need conversion"
        ))
    }

    static func isMedia(_ key: String) -> Bool { MediaRules.kind(of: key) != nil }

    static func engine(for runtime: RuntimeIdentifier) -> MediaEngine? {
        switch runtime {
        case .web: .webKit
        case .rgss: .mkxp
        case .renpy: .renpy
        default: nil
        }
    }

    /// Nil means nothing to record for this file. The conversions themselves follow `MediaRules`, the same table the
    /// app prepares media from before launch, so what detection reports is what preparation does.
    static func action(for info: MediaProbeResult, runtime: RuntimeIdentifier, ctx: ScanContext) -> MediaRequirement.Action? {
        let ext = MediaRules.pathExtension(info.path)
        let stem = ext.isEmpty ? info.path : String(info.path.dropLast(ext.count + 1))
        // MV picks .ogg or .m4a by what it thinks WebKit plays; with no .m4a beside it, the shim keeps it on .ogg,
        // which the web runtime decodes itself.
        if case .web = runtime, ext == "ogg", info.audio != .opus, !ctx.exists(stem + ".m4a") {
            return .shim("audioFileExtOgg")
        }
        guard let engine = engine(for: runtime), let kind = MediaRules.kind(of: info.path),
              let target = MediaRules.conversion(for: info.path, engine: engine, probe: info) else { return nil }
        // A sibling counts when it is a different file the engine plays as it is (x.webm beside x.mp4, not an Opus
        // x.ogg beside x.opus for mkxp-z).
        for ext in MediaRules.playableSiblings(for: kind, engine: engine) {
            let sibling = stem + "." + ext
            guard sibling.lowercased() != info.path.lowercased(), let url = ctx.url(sibling) else { continue }
            let probe = MediaRules.needsProbe(sibling, engine: engine) ? MediaProbe.probe(url, relativePath: sibling) : nil
            if MediaRules.conversion(for: sibling, engine: engine, probe: probe) == nil {
                return .useSibling(sibling)
            }
        }
        return .transcode(target: target.rawValue)
    }
}
