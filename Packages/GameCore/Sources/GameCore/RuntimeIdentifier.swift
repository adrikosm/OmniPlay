/// One embedded runtime, precise enough to pick a session slot.
public enum RuntimeIdentifier: Codable, Sendable, Hashable {
    case web
    case rgss(ruby: RubyLine)
    case renpy(engine: RenPyEngine)
    case easyrpg
    case scummvm
    case godot(bucket: GodotBucket)
    case love
    case onscripter
    case tic80

    public var slot: SessionSlot {
        switch self {
        case .web: .web
        case let .rgss(ruby): ruby.slot
        case let .renpy(engine): engine.slot
        case .easyrpg: .easyrpg
        case .scummvm: .scummvm
        case let .godot(bucket): bucket.slot
        case .love: .love
        case .onscripter: .onscripter
        case .tic80: .tic80
        }
    }
}

public enum RubyLine: String, Codable, Sendable, CaseIterable, Hashable {
    case ruby18, ruby19, ruby31
    public var slot: SessionSlot { SessionSlot(rawValue: rawValue)! }
}

public enum RenPyEngine: String, Codable, Sendable, CaseIterable, Hashable {
    case v787, v837, v853
    public var slot: SessionSlot { SessionSlot(rawValue: "renpy" + rawValue.dropFirst())! }
}

public enum GodotBucket: String, Codable, Sendable, CaseIterable, Hashable {
    case v36, v44, v47
    public var slot: SessionSlot { SessionSlot(rawValue: "godot" + rawValue.dropFirst())! }
}
