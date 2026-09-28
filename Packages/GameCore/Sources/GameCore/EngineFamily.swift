/// Engines OmniPlay can identify. Refused families are named so detection can say exactly why a
/// title will not run instead of shrugging.
public enum EngineFamily: String, Codable, Sendable, CaseIterable, Hashable {
    case rpgMakerMV, rpgMakerMZ, rpgMakerXP, rpgMakerVX, rpgMakerVXAce, rpgMaker2000, rpgMaker2003
    case renpy, html5, godot, scummvm, love, onscripter, tic80, flash, unityWeb, godotWeb
    case unityNative, unreal, gameMaker, clickteam, bakin, smileGameBuilder, srpgStudio, pixelGameMakerMV
    case wolfRPG, kirikiri, yuris, artemis, siglus
    case unknown

    public var tier: EligibilityTier {
        switch self {
        case .rpgMakerMV, .rpgMakerMZ, .rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce, .renpy, .html5: .core
        case .rpgMaker2000, .rpgMaker2003, .scummvm, .love, .onscripter, .tic80, .flash, .unityWeb, .godotWeb: .breadth
        case .godot, .kirikiri: .opportunistic
        case .unityNative, .unreal, .gameMaker, .clickteam, .bakin, .smileGameBuilder, .srpgStudio, .pixelGameMakerMV,
             .wolfRPG, .yuris, .artemis, .siglus, .unknown: .refused
        }
    }
}

public enum EligibilityTier: String, Codable, Sendable, CaseIterable {
    case core, breadth, opportunistic, refused
}
