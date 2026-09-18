/// The only compatibility vocabulary the project keeps (design authority §1.1). Ordered.
public enum PlayabilityGrade: Int, Codable, Sendable, CaseIterable, Comparable {
    case refused
    case loadable
    case intro
    case menu
    case ingame
    case playable

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
