import Foundation
import GameCore
import GRDB

/// Game IDs are stored as their upper-case UUID string so raw SQL can compare against `GameID.description`.
extension GameID: @retroactive DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { description.databaseValue }
    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> GameID? {
        String.fromDatabaseValue(dbValue).flatMap(GameID.init(uuidString:))
    }
}

/// Swift names are camelCase, columns are snake_case; enums with associated values and arrays land in JSON columns;
/// UUIDs are stored as upper-case strings.
public protocol StoreRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {}
public extension StoreRecord {
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy { .convertFromSnakeCase }
    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy { .convertToSnakeCase }
    static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { .uppercaseString }
}

/// Rows with an AUTOINCREMENT id: `id` is nil until inserted.
public protocol AutoIDRecord: Codable, Sendable, Hashable, FetchableRecord, MutablePersistableRecord {
    var id: Int64? { get set }
}

public extension AutoIDRecord {
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy { .convertFromSnakeCase }
    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy { .convertToSnakeCase }
    static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { .uppercaseString }
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct GameRecord: StoreRecord, Identifiable {
    public static let databaseTableName = "games"
    public var id: GameID
    public var title: String
    public var rootRelPath: String = ""
    public var engine: EngineFamily
    public var generation: EngineGeneration?
    public var version: String?
    public var runtime: RuntimeIdentifier?
    public var runtimeVersion: String?
    public var detectionConfidence: Double = 0
    public var compatibilityState: PlayabilityGrade = .loadable
    public var installBytes: Int64 = 0
    public var saveFamily: String?
    public var artworkPath: String?
    public var importedAt: Date = .now
    public var lastPlayedAt: Date?
    public var playTimeS: Int = 0
    public var favorite = false
    public var hidden = false
    public var manualRuntimeOverride: RuntimeIdentifier?
    public var compatProfileJson = CompatibilityProfile()

    public init(id: GameID = GameID(), title: String, engine: EngineFamily) {
        self.id = id
        self.title = title
        self.engine = engine
    }
}

public struct DetectionResultRecord: AutoIDRecord {
    public static let databaseTableName = "detection_results"
    public var id: Int64?
    public var gameId: GameID
    public var outcome: String
    public var confidence: Double
    public var evidenceJson: [EvidenceRecord]
    public var detectorVersionsJson: [String: String]
    public var createdAt: Date = .now

    public init(gameId: GameID, outcome: String, confidence: Double, evidence: [EvidenceRecord], detectorVersions: [String: String]) {
        self.gameId = gameId
        self.outcome = outcome
        self.confidence = confidence
        evidenceJson = evidence
        detectorVersionsJson = detectorVersions
    }
}

public struct RuntimeSelectionRecord: AutoIDRecord {
    public static let databaseTableName = "runtime_selections"
    public var id: Int64?
    public var gameId: GameID
    public var selectedRuntime: RuntimeIdentifier
    public var version: String?
    public var reason: String
    public var warningsJson: [String]
    public var fallbacksJson: [RuntimeIdentifier]
    public var createdAt: Date = .now

    public init(
        gameId: GameID,
        selectedRuntime: RuntimeIdentifier,
        version: String? = nil,
        reason: String,
        warnings: [String] = [],
        fallbacks: [RuntimeIdentifier] = []
    ) {
        self.gameId = gameId
        self.selectedRuntime = selectedRuntime
        self.version = version
        self.reason = reason
        warningsJson = warnings
        fallbacksJson = fallbacks
    }
}

public struct SessionRecord: StoreRecord, Identifiable {
    public static let databaseTableName = "sessions"
    public var id: UUID
    public var gameId: GameID
    public var runtime: RuntimeIdentifier
    public var slot: SessionSlot
    public var startedAt: Date = .now
    public var endedAt: Date?
    public var teardownVerdict: String?
    public var grade: PlayabilityGrade?
    public var peakFootprint: Int64?
    public var notes: String?

    public init(id: UUID, gameId: GameID, runtime: RuntimeIdentifier) {
        self.id = id
        self.gameId = gameId
        self.runtime = runtime
        slot = runtime.slot
    }
}

public struct ImportRecord: AutoIDRecord {
    public static let databaseTableName = "import_records"
    public var id: Int64?
    public var gameId: GameID?
    public var sourceName: String
    public var container: String
    public var sourceSha256: String
    public var bytes: Int64
    public var outcome: String
    public var error: String?
    public var createdAt: Date = .now

    public init(
        gameId: GameID?,
        sourceName: String,
        container: String,
        sourceSha256: String,
        bytes: Int64,
        outcome: String,
        error: String? = nil
    ) {
        self.gameId = gameId
        self.sourceName = sourceName
        self.container = container
        self.sourceSha256 = sourceSha256
        self.bytes = bytes
        self.outcome = outcome
        self.error = error
    }
}

public struct MediaJobRecord: AutoIDRecord {
    public static let databaseTableName = "media_jobs"
    public var id: Int64?
    public var gameId: GameID
    public var inputRel: String
    public var outputRel: String
    public var sourceCodec: String
    public var targetCodec: String
    public var targetRuntime: String
    public var reason: String
    public var state: String
    public var progress: Double = 0
    public var bytesOut: Int64 = 0
    public var error: String?

    public init(
        gameId: GameID,
        inputRel: String,
        outputRel: String,
        sourceCodec: String,
        targetCodec: String,
        targetRuntime: String,
        reason: String,
        state: String
    ) {
        self.gameId = gameId
        self.inputRel = inputRel
        self.outputRel = outputRel
        self.sourceCodec = sourceCodec
        self.targetCodec = targetCodec
        self.targetRuntime = targetRuntime
        self.reason = reason
        self.state = state
    }
}

public struct SaveMetaRecord: AutoIDRecord {
    public static let databaseTableName = "saves_meta"
    public var id: Int64?
    public var gameId: GameID
    public var slotKey: String
    public var relPath: String
    public var family: String
    public var bytes: Int64
    public var modifiedAt: Date
    public var provenanceHash: String

    public init(
        gameId: GameID,
        slotKey: String,
        relPath: String,
        family: String,
        bytes: Int64,
        modifiedAt: Date,
        provenanceHash: String
    ) {
        self.gameId = gameId
        self.slotKey = slotKey
        self.relPath = relPath
        self.family = family
        self.bytes = bytes
        self.modifiedAt = modifiedAt
        self.provenanceHash = provenanceHash
    }
}

public struct PersistentStoreRecord: AutoIDRecord {
    public static let databaseTableName = "persistent_stores"
    public var id: Int64?
    public var gameId: GameID
    public var kind: String
    public var relPath: String
    public var bytes: Int64
    public var modifiedAt: Date

    public init(gameId: GameID, kind: String, relPath: String, bytes: Int64, modifiedAt: Date) {
        self.gameId = gameId
        self.kind = kind
        self.relPath = relPath
        self.bytes = bytes
        self.modifiedAt = modifiedAt
    }
}

public struct ModRecord: StoreRecord, Identifiable {
    public static let databaseTableName = "mods"
    public var id: String
    public var gameId: GameID
    public var name: String
    public var source: String
    public var installedAt: Date = .now
    public var enabled = true
    public var priority = 0
    public var contentType: String
    public var engineCompatJson: [String] = []
    public var filesJson: [String] = []
    public var conflictsJson: [String] = []

    public init(id: String, gameId: GameID, name: String, source: String, contentType: String) {
        self.id = id
        self.gameId = gameId
        self.name = name
        self.source = source
        self.contentType = contentType
    }
}

public struct TranslationPackRecord: StoreRecord, Identifiable {
    public static let databaseTableName = "translation_packs"
    public var id: String
    public var gameId: GameID
    public var name: String
    public var source: String
    public var installedAt: Date = .now
    public var enabled = true
    public var priority = 0
    public var contentType: String
    public var engineCompatJson: [String] = []
    public var filesJson: [String] = []
    public var conflictsJson: [String] = []
    public var format: String
    public var language: String

    public init(id: String, gameId: GameID, name: String, source: String, contentType: String, format: String, language: String) {
        self.id = id
        self.gameId = gameId
        self.name = name
        self.source = source
        self.contentType = contentType
        self.format = format
        self.language = language
    }
}

public struct OverrideRecord: StoreRecord {
    public static let databaseTableName = "overrides_ledger"
    public var gameId: GameID
    public var key: String
    public var valueJson: String
    public var createdAt: Date = .now
    public init(gameId: GameID, key: String, valueJson: String) {
        self.gameId = gameId
        self.key = key
        self.valueJson = valueJson
    }
}

public struct SlotLedgerRecord: StoreRecord {
    public static let databaseTableName = "slot_ledger"
    public var processBootId: String
    public var slot: SessionSlot
    public var spent: Bool
    public var spentByGame: GameID?
    public init(processBootId: String, slot: SessionSlot, spent: Bool, spentByGame: GameID?) {
        self.processBootId = processBootId
        self.slot = slot
        self.spent = spent
        self.spentByGame = spentByGame
    }
}
