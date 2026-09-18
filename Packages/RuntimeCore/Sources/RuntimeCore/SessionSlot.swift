/// One engine copy that can host at most one game per process unless the engine provides a
/// sanctioned in-process restart (design authority §14.2). Declared, not discovered: the
/// coordinator knows before launch whether a slot is spent.
public enum SessionSlot: String, Codable, Sendable, CaseIterable, Hashable {
    case web
    case scummvm
    case ruby18
    case ruby19
    case ruby31
    case renpy853
    case renpy837
    case renpy787
    case easyrpg
    case godot47
    case godot44
    case love
    case onscripter
    case tic80

    public var capacity: SlotCapacity {
        switch self {
        case .web, .scummvm:
            .unlimited
        case .easyrpg:
            .unlimitedUnverified
        case .ruby18, .ruby19, .ruby31, .renpy853, .renpy837, .renpy787,
             .godot47, .godot44, .love, .onscripter, .tic80:
            .one
        }
    }
}

public enum SlotCapacity: Sendable, Equatable {
    /// New engine instance per game (WKWebView; ScummVM by design).
    case unlimited
    /// One game per process; same-game restart allowed.
    case one
    /// Expected unlimited but not proven by the alternation matrix. Treated as `.one` until it is.
    case unlimitedUnverified

    /// The ledger never attempts a reset it cannot prove.
    public var isProvenUnlimited: Bool { self == .unlimited }
}
