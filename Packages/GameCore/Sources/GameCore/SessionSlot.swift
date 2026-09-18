/// One engine copy that can host at most one game per process unless the engine offers a sanctioned
/// in-process restart. Declared, not discovered: the coordinator knows before launch whether a slot is spent.
public enum SessionSlot: String, Codable, Sendable, CaseIterable, Hashable {
    case web, scummvm
    case ruby18, ruby19, ruby31
    case renpy787, renpy837, renpy853
    case easyrpg
    case godot44, godot47
    case love, onscripter, tic80

    public var sessionsPerProcess: SlotCapacity {
        switch self {
        case .web, .scummvm: .unlimited
        case .renpy787, .renpy837, .renpy853: .oneWithSoftRestart
        // easyrpg is expected to be unlimited but unproven; treated as one-shot until the alternation matrix says otherwise.
        case .ruby18, .ruby19, .ruby31, .easyrpg, .godot44, .godot47, .love, .onscripter, .tic80: .one
        }
    }
}

public enum SlotCapacity: String, Codable, Sendable, Hashable {
    /// New engine instance per game.
    case unlimited
    /// One game per process; same-game restart allowed.
    case one
    /// One game per process, but the engine is expected to restart into another title of the same engine.
    /// The ledger treats it as `.one` until a soft restart is proven on device.
    case oneWithSoftRestart
}
