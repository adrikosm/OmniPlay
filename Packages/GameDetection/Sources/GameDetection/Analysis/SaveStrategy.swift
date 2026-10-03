import GameCore

/// Where a game keeps saves and persistent data.
public struct SaveStrategy: Sendable, Hashable, Codable {
    public enum PersistentStoreKind: String, Sendable, Codable {
        case webLocalStorage, webIndexedDB, mvGlobalConfig, renpyPersistent, rgssNone
    }

    public let family: SaveFamily
    public let slotPattern: String?
    public let persistentStores: [PersistentStoreKind]

    public static func forEngine(_ engine: EngineFamily, generation: EngineGeneration?) -> SaveStrategy {
        switch engine {
        case .rpgMakerMV:
            .init(family: .webLocalStorage, slotPattern: "file%d.rpgsave", persistentStores: [.webLocalStorage, .mvGlobalConfig])
        case .rpgMakerMZ:
            .init(family: .webIndexedDB, slotPattern: "file%d.rmmzsave", persistentStores: [.webIndexedDB, .mvGlobalConfig])
        case .rpgMakerXP: .init(family: .rgssMarshal, slotPattern: "Save%d.rxdata", persistentStores: [.rgssNone])
        case .rpgMakerVX: .init(family: .rgssMarshal, slotPattern: "Save%d.rvdata", persistentStores: [.rgssNone])
        case .rpgMakerVXAce: .init(family: .rgssMarshal, slotPattern: "Save%02d.rvdata2", persistentStores: [.rgssNone])
        case .renpy: .init(family: .renpySave, slotPattern: "%d-LT1.save", persistentStores: [.renpyPersistent])
        case .rpgMaker2000, .rpgMaker2003: .init(family: .easyrpgLSD, slotPattern: "Save%02d.lsd", persistentStores: [])
        case .scummvm: .init(family: .scummvm, slotPattern: nil, persistentStores: [])
        case .godot: .init(family: .godotUserDir, slotPattern: nil, persistentStores: [])
        case .love: .init(family: .love, slotPattern: nil, persistentStores: [])
        case .html5, .unityWeb, .godotWeb, .flash:
            .init(family: .webLocalStorage, slotPattern: nil, persistentStores: [.webLocalStorage, .webIndexedDB])
        default: .init(family: .unknown, slotPattern: nil, persistentStores: [])
        }
    }
}

/// Fills the save family and notes saves shipped inside the game folder.
public struct SaveStrategyAnalyzer: Analyzer {
    public let id = DetectorID.saveFamily
    public let version = 1
    public init() {}

    public func analyze(_ ctx: ScanContext, facts: StructureFacts, partial: inout PartialDescriptor, evidence: inout [DetectionEvidence]) {
        guard let engine = partial.engine else { return }
        let strategy = SaveStrategy.forEngine(engine, generation: partial.generation)
        partial.saveFamily = partial.saveFamily ?? strategy.family
        let bundled = ctx.glob("save/*", limit: 4) + ctx.glob("www/save/*", limit: 4) + ctx.glob("game/saves/*", limit: 4) + ctx.glob(
            "save*.rvdata2",
            limit: 4
        ) + ctx.glob("save*.lsd", limit: 4)
        if !bundled.isEmpty {
            partial.profileHints["bundledSaves"] = "true"
            evidence.append(DetectionEvidence(
                id,
                .count(path: "save", n: bundled.count),
                confidence: 0.7,
                source: .directoryStructure,
                "The game ships with \(bundled.count) save files"
            ))
        }
    }
}
