/// Engines OmniPlay can identify. Eligibility tiers follow design authority §3; `refused` families
/// are still named so detection can explain *why* a title will not run (§17 step 6).
public enum EngineFamily: String, Codable, Sendable, CaseIterable, Hashable {
    // Tier 1 — the core
    case rpgMakerMV
    case rpgMakerMZ
    case rpgMakerXP
    case rpgMakerVX
    case rpgMakerVXAce
    case renpy
    case html5
    // Tier 2 — breadth
    case rpgMaker2000
    case rpgMaker2003
    case unityWeb
    case godotWeb
    case scummvm
    case ruffle
    case love
    case onscripter
    case tic80
    case pico8
    // Tier 3 — opportunistic
    case godot
    // Refused families (named so the refusal message can be exact)
    case unityNative
    case unreal
    case gameMakerNative
    case clickteam
    case wolfRPG
    case kirikiri
    case unknown

    public var tier: EligibilityTier {
        switch self {
        case .rpgMakerMV, .rpgMakerMZ, .rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce, .renpy, .html5:
            .core
        case .rpgMaker2000, .rpgMaker2003, .unityWeb, .godotWeb, .scummvm, .ruffle, .love, .onscripter, .tic80, .pico8:
            .breadth
        case .godot:
            .opportunistic
        case .unityNative, .unreal, .gameMakerNative, .clickteam, .wolfRPG, .kirikiri, .unknown:
            .refused
        }
    }
}

public enum EligibilityTier: String, Codable, Sendable, CaseIterable {
    case core
    case breadth
    case opportunistic
    case refused
}
