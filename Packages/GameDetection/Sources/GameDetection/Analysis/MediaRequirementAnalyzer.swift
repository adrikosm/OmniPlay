import Foundation
import GameCore
import MediaCompat
import OverlayVFS

/// Plans what each media file needs before the chosen runtime can play it. WebKit: VP9 WebM needs an MP4 sibling
/// or a transcode; Ren'Py wants WebM; mkxp-z and Godot want Theora; MIDI needs a soundfont.
public struct MediaRequirementAnalyzer: Analyzer {
    public let id = DetectorID.media
    public let version = 1
    public static let fileCap = 2000
    public init() {}

    public func analyze(_ ctx: ScanContext, facts: StructureFacts, partial: inout PartialDescriptor, evidence: inout [DetectionEvidence]) {
        guard let runtime = partial.runtimeCandidates.first?.runtime else { return }
        let patterns = ["movies/*", "www/movies/*", "audio/*/*", "www/audio/*/*", "game/*", "game/*/*", "audio/*", "movies/*/*"]
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
            let info = MediaProbe.probe(url, relativePath: e.realRel)
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

    static func isMedia(_ key: String) -> Bool {
        [".webm", ".mp4", ".m4v", ".ogg", ".ogv", ".m4a", ".mp3", ".wav", ".mid", ".midi", ".opus"].contains { key.hasSuffix($0) }
    }

    /// Nil means nothing to record for this file.
    static func action(for info: MediaProbeResult, runtime: RuntimeIdentifier, ctx: ScanContext) -> MediaRequirement.Action? {
        let stem = String(info.path.prefix(info.path.count - (info.path.split(separator: ".").last?.count ?? 0) - 1))
        switch runtime {
        case .web:
            if info.container == .webm, info.video == .vp9 || info.video == .av1 || info.video == .unknown {
                return ctx.exists(stem + ".mp4") ? .useSibling(stem + ".mp4") : .transcode(target: "mp4/h264/aac")
            }
            if info.container == .webm, info.video == .vp8 {
                return .none
            }
            if info.container == .ogg, !ctx.exists(stem + ".m4a") {
                return .shim("audioFileExtOgg")
            }
            return nil
        case .renpy:
            if info.container == .mp4, info.video == .h264 || info.video == .hevc {
                return .transcode(target: "webm/vp8/opus")
            }
            return nil
        case .rgss, .godot:
            if info.video != nil, info.video != .theora {
                return .transcode(target: "ogv/theora/vorbis")
            }
            return nil
        default:
            return nil
        }
    }
}
