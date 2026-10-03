import GameCore

/// What the web runtime does about a title's media before launch, from the detection report alone.
/// WebKit never gets MP4 bytes under a `.webm` name: the compat shim makes RPG Maker ask for `.mp4`, so a sibling
/// with a different extension needs no alias. Aliases cover siblings that keep the extension but live elsewhere.
public struct MediaPlan: Sendable, Hashable {
    public var aliases: [String: String] = [:]

    public init(requirements: [MediaRequirement]) {
        for r in requirements {
            if case let .useSibling(sibling) = r.action, Self.ext(sibling) == Self.ext(r.sourceRel), sibling != r.sourceRel {
                aliases[r.sourceRel] = sibling
            }
        }
    }

    static func ext(_ path: String) -> Substring { path.split(separator: ".").last ?? "" }
}
