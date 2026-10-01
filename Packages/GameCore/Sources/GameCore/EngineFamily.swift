/// Engines OmniPlay can identify. Refused families are named so detection can say exactly why a
/// title will not run instead of shrugging.
public enum EngineFamily: String, Codable, Sendable, CaseIterable, Hashable {
    case rpgMakerMV, rpgMakerMZ, rpgMakerXP, rpgMakerVX, rpgMakerVXAce, rpgMaker2000, rpgMaker2003
    case renpy, html5, godot, scummvm, love, onscripter, tic80, flash, unityWeb, godotWeb
    case unityNative, unreal, gameMaker, clickteam, bakin, smileGameBuilder, srpgStudio, pixelGameMakerMV
    case kirikiri, yuris, artemis, siglus
    case unknown

    /// A family no longer in the app (Wolf RPG, removed 1 Oct 2026) can still be stored in a library or a game's
    /// detection report; it reads as unknown instead of failing the whole library.
    public init(from decoder: Decoder) throws {
        self = try Self(rawValue: decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }

    public var tier: EligibilityTier {
        switch self {
        case .rpgMakerMV, .rpgMakerMZ, .rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce, .renpy, .html5: .core
        case .rpgMaker2000, .rpgMaker2003, .scummvm, .love, .onscripter, .tic80, .flash, .unityWeb, .godotWeb: .breadth
        case .godot, .kirikiri: .opportunistic
        case .unityNative, .unreal, .gameMaker, .clickteam, .bakin, .smileGameBuilder, .srpgStudio, .pixelGameMakerMV,
             .yuris, .artemis, .siglus, .unknown: .refused
        }
    }
}

public enum EligibilityTier: String, Codable, Sendable, CaseIterable {
    case core, breadth, opportunistic, refused
}
