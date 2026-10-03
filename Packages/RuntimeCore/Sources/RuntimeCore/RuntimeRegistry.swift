import GameCore

public struct RuntimeCapabilityFlags: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let inspectVariables = Self(rawValue: 1 << 0)
    public static let mutateVariables = Self(rawValue: 1 << 1)
    public static let editSwitches = Self(rawValue: 1 << 2)
    public static let cheats = Self(rawValue: 1 << 3)
    public static let mods = Self(rawValue: 1 << 4)
    public static let translationPacks = Self(rawValue: 1 << 5)
    public static let saves = Self(rawValue: 1 << 6)
    public static let persistentData = Self(rawValue: 1 << 7)
    public static let renpyConsole = Self(rawValue: 1 << 8)
    public static let renpyScriptInjection = Self(rawValue: 1 << 9)
    public static let freezeVariables = Self(rawValue: 1 << 10)
    public static let watchVariables = Self(rawValue: 1 << 11)
    public static let editInventory = Self(rawValue: 1 << 12)
    public static let editParty = Self(rawValue: 1 << 13)
    public static let fastForward = Self(rawValue: 1 << 14)
    public static let screenshot = Self(rawValue: 1 << 15)
}

/// What a runtime can host, declared before any adapter exists so the resolver can answer honestly.
public struct RuntimeDescriptor: Sendable, Hashable, Codable {
    public enum Availability: String, Sendable, Codable { case bundled, notBuilt }

    public let id: RuntimeIdentifier
    public let supportedFamilies: [EngineFamily]
    public let supportedGenerations: [EngineGeneration]
    public let version: String
    public let flags: RuntimeCapabilityFlags
    public let availability: Availability
    public var slot: SessionSlot { id.slot }

    public init(
        id: RuntimeIdentifier,
        families: [EngineFamily],
        generations: [EngineGeneration],
        version: String,
        flags: RuntimeCapabilityFlags,
        availability: Availability
    ) {
        self.id = id
        supportedFamilies = families
        supportedGenerations = generations
        self.version = version
        self.flags = flags
        self.availability = availability
    }
}

/// The runtimes this build knows about. Adapters register themselves as `.bundled` when they land.
public actor RuntimeRegistry {
    private var descriptors: [RuntimeIdentifier: RuntimeDescriptor] = [:]

    public init(descriptors: [RuntimeDescriptor] = RuntimeRegistry.planned) {
        for d in descriptors {
            self.descriptors[d.id] = d
        }
    }

    public func register(_ descriptor: RuntimeDescriptor) { descriptors[descriptor.id] = descriptor }

    public func descriptor(for id: RuntimeIdentifier) -> RuntimeDescriptor? { descriptors[id] }

    /// Every runtime the roadmap plans, none built yet.
    public static let planned: [RuntimeDescriptor] = [
        .init(
            id: .web,
            families: [.rpgMakerMV, .rpgMakerMZ, .html5, .unityWeb, .godotWeb, .flash],
            generations: [.mv, .mz],
            version: "webkit",
            flags: [.saves, .persistentData, .mods, .translationPacks, .screenshot],
            availability: .notBuilt
        ),
        .init(
            id: .rgss(ruby: .ruby18),
            families: [.rpgMakerXP, .rpgMakerVX],
            generations: [.rgss1, .rgss2],
            version: "mkxp-z ruby 1.8",
            flags: [.saves, .mods, .translationPacks, .inspectVariables, .mutateVariables, .editSwitches, .cheats, .screenshot],
            availability: .notBuilt
        ),
        .init(
            id: .rgss(ruby: .ruby19),
            families: [.rpgMakerVXAce],
            generations: [.rgss3],
            version: "mkxp-z ruby 1.9",
            flags: [.saves, .mods, .translationPacks, .inspectVariables, .mutateVariables, .editSwitches, .cheats, .screenshot],
            availability: .notBuilt
        ),
        .init(
            id: .rgss(ruby: .ruby31),
            families: [.rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce],
            generations: [.rgss1, .rgss2, .rgss3],
            version: "mkxp-z ruby 3.1",
            flags: [.saves, .mods, .translationPacks, .inspectVariables, .mutateVariables, .editSwitches, .cheats, .screenshot],
            availability: .notBuilt
        ),
        .init(
            id: .renpy(engine: .v787),
            families: [.renpy],
            generations: [.renpyPy27],
            version: "7.8.7",
            flags: [.saves, .persistentData, .mods, .renpyConsole, .screenshot],
            availability: .notBuilt
        ),
        .init(
            id: .renpy(engine: .v837),
            families: [.renpy],
            generations: [.renpyPy39],
            version: "8.3.7",
            flags: [.saves, .persistentData, .mods, .renpyConsole, .screenshot],
            availability: .notBuilt
        ),
        .init(
            id: .renpy(engine: .v853),
            families: [.renpy],
            generations: [.renpyPy27, .renpyPy39, .renpyPy312],
            version: "8.5.3",
            flags: [.saves, .persistentData, .mods, .renpyConsole, .screenshot],
            availability: .notBuilt
        ),
        .init(
            id: .easyrpg,
            families: [.rpgMaker2000, .rpgMaker2003],
            generations: [],
            version: "0.8",
            flags: [.saves, .screenshot],
            availability: .notBuilt
        ),
        .init(
            id: .scummvm,
            families: [.scummvm],
            generations: [],
            version: "2026.3.0",
            flags: [.saves, .screenshot],
            availability: .notBuilt
        ),
        .init(
            id: .godot(bucket: .v36),
            families: [.godot],
            generations: [.godot3x],
            version: "3.6",
            flags: [.saves, .screenshot],
            availability: .notBuilt
        ),
        .init(
            id: .godot(bucket: .v44),
            families: [.godot],
            generations: [.godot4x],
            version: "4.4",
            flags: [.saves, .screenshot],
            availability: .notBuilt
        ),
        .init(
            id: .godot(bucket: .v47),
            families: [.godot],
            generations: [.godot4x],
            version: "4.7",
            flags: [.saves, .screenshot],
            availability: .notBuilt
        ),
    ]
}
