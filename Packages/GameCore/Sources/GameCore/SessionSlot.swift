/// One engine copy that can host at most one game per process unless the engine offers a sanctioned
/// in-process restart. Declared, not discovered: the coordinator knows before launch whether a slot is spent.
public enum SessionSlot: String, Codable, Sendable, CaseIterable, Hashable {
    case web, scummvm
    case ruby18, ruby19, ruby31
    case renpy787, renpy837, renpy853
    case easyrpg
    case godot36, godot44, godot47
    case love, onscripter, tic80

    public var sessionsPerProcess: SlotCapacity {
        switch self {
        case .web, .scummvm: .unlimited
        case .renpy787, .renpy837, .renpy853: .oneWithSoftRestart
        // easyrpg is expected to be unlimited but unproven; treated as one-shot until the alternation matrix says otherwise.
        case .ruby18, .ruby19, .ruby31, .easyrpg, .godot36, .godot44, .godot47, .love, .onscripter, .tic80: .one
        }
    }

    /// Slots that die together because one process-wide engine boot hosts all of them, this one included.
    /// The three Ruby lines are islanded inside a single mkxp-z engine whose `main()` runs once and exits
    /// with the session, so spending one spends the other two. Every other slot stands alone.
    public var diesWith: Set<SessionSlot> {
        switch self {
        case .ruby18, .ruby19, .ruby31: [.ruby18, .ruby19, .ruby31]
        default: [self]
        }
    }
}

public enum SlotCapacity: String, Codable, Sendable, Hashable {
    /// New engine instance per game.
    case unlimited
    /// One game per process; same-game restart allowed.
    case one
    /// One engine boot per process that restarts into another title of its own in place (Ren'Py's restart loop).
    /// The adapter's verdict decides: `.clean` means the engine parked and is free for any game.
    case oneWithSoftRestart
}
