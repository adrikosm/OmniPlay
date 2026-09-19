import GameCore

/// What the web runtime does about a title's media before launch, from the detection report alone.
/// WebKit never gets MP4 bytes under a `.webm` name: the compat shim makes RPG Maker ask for `.mp4`, so a sibling
/// with a different extension needs no alias. Aliases cover siblings that keep the extension but live elsewhere.
public struct MediaPlan: Sendable, Hashable {
    public var aliases: [String: String] = [:]
    public var pendingTranscodes: [MediaRequirement] = []

    public init(requirements: [MediaRequirement]) {
        for r in requirements {
            switch r.action {
            case let .useSibling(sibling) where Self.ext(sibling) == Self.ext(r.sourceRel) && sibling != r.sourceRel:
                aliases[r.sourceRel] = sibling
            case .transcode:
                pendingTranscodes.append(r)
            default: break
            }
        }
    }

    /// Player-facing line for the launch notice, or nil when everything plays as shipped.
    public var notice: String? {
        switch pendingTranscodes.count {
        case 0: nil
        case 1: "One video needs converting and may not play yet."
        case let n: "\(n) videos need converting and may not play yet."
        }
    }

    static func ext(_ path: String) -> Substring { path.split(separator: ".").last ?? "" }
}
