import Diagnostics
import Foundation
import GameCore
import OSLog
import SaveKit

/// Routes web-storage writes to files and seeds the page from them on launch. Save slots go to
/// `Saves/slots`; everything else (RPG Maker config and global data, a plain HTML5 game's whole localStorage) is a
/// persistent store under `Saves/persistent/webLocalStorage` or `webIndexedDB`, backed up and reset separately.
/// `ls` entries are UTF-8 strings under `ls.<base64url(key)>.<ext>`; `mz` entries are RPG Maker MZ deflate blobs,
/// carried as base64 and stored raw under `<key>.rmmzsave`.
public actor SaveBridge {
    public struct Kind: Sendable, Hashable {
        public let name: String
        public let fileExtension: String
        public let binary: Bool
    }

    public let location: SaveLocation
    public let kinds: [Kind]
    private let session: SessionID?
    /// Maximum source bytes loaded at launch. The page cannot lazily read omitted saves.
    public static let maxSeedBytes = 32 << 20

    public init(location: SaveLocation, engine: EngineFamily, session: SessionID? = nil) {
        self.location = location
        self.session = session
        kinds = [
            Kind(name: "ls", fileExtension: engine == .rpgMakerMV ? "rpgsave" : "webstorage", binary: false),
            Kind(name: "mz", fileExtension: "rmmzsave", binary: true),
        ]
    }

    /// The two directories a kind can live in: slots first, then its persistent store.
    func stores(_ kind: Kind) -> [SaveFileStore] {
        let persistent = location.persistent.appending(
            path: kind.name == "ls" ? "webLocalStorage" : "webIndexedDB",
            directoryHint: .isDirectory
        )
        return [
            SaveFileStore(location: location, fileExtension: kind.fileExtension),
            SaveFileStore(location: location, fileExtension: kind.fileExtension, directory: persistent),
        ]
    }

    /// MV `RPG File<n>`, MZ `rmmzsave.<game>.file<n>` and Tyrano's `<project>_tyrano_data` (every slot in one value),
    /// quick save and auto save are slots; nothing else is. Tyrano's `<project>_sf` system variables stay persistent.
    static func isSlot(kind: String, key: String) -> Bool {
        kind == "ls" ? key.wholeMatch(of: /RPG File\d+|.+_tyrano_(data|quick_save|auto_save)/) != nil
            : key.wholeMatch(of: /rmmzsave\..*\.file\d+/) != nil
    }

    func store(_ kind: Kind, key: String) -> SaveFileStore {
        let both = stores(kind)
        return Self.isSlot(kind: kind.name, key: key) ? both[0] : both[1]
    }

    func stem(_ kind: Kind, key: String) -> String { kind.name == "ls" ? SaveKey.encodeWebStorage(key) : key }

    public enum Failure: Error, CustomStringConvertible {
        case invalidMessage(String), incompleteSeed(String), seedFull

        public var description: String {
            switch self {
            case let .invalidMessage(detail): detail
            case .seedFull: "The game's saves together would pass the 32 MB launch limit."
            case let .incompleteSeed(detail):
                "The game could not start because its saves could not all be loaded. \(detail) Your save files have been kept."
            }
        }
    }

    /// A reply is successful only after the atomic file operation succeeds. Isolated on this actor so
    /// file writes and fsync never run on the UI actor.
    public func handle(op: String, kind kindName: String, key: String, value: String?) throws {
        guard let kind = kinds.first(where: { $0.name == kindName }) else { throw Failure.invalidMessage("unknown save kind") }
        let store = store(kind, key: key)
        switch op {
        case "write":
            guard let value else { throw Failure.invalidMessage("write without value") }
            let limit = kind.binary ? ((SaveFileStore.maxBytes + 2) / 3) * 4 : SaveFileStore.maxBytes
            guard value.utf8.count <= limit else { throw SaveFileStore.Failure.tooLarge(value.utf8.count) }
            guard let data = kind.binary ? Data(base64Encoded: value) : Data(value.utf8) else {
                throw Failure.invalidMessage("invalid base64 save")
            }
            try requireSeedRoom(for: data.count, replacing: store.url(for: stem(kind, key: key)))
            try store.write(data, key: stem(kind, key: key))
            log(.debug, "wrote \(kind.name) \(key) (\(data.count) bytes)")
        case "remove":
            try store.remove(key: stem(kind, key: key))
            log(.debug, "removed \(kind.name) \(key)")
        case "seedFailed":
            throw Failure.incompleteSeed("Web storage refused the saved data.")
        default: throw Failure.invalidMessage("unknown save operation")
        }
    }

    /// What the player is told when a write fails; the full error goes to the session log.
    public static func playerMessage(for error: Error) -> String {
        let nsError = error as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        if nsError.code == NSFileWriteOutOfSpaceError || (underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(ENOSPC)) {
            return "The iPhone is out of storage, so the save was not written."
        }
        if case Failure.seedFull = error {
            return "This game's saves together have reached the 32 MB OmniPlay can load, so the save was not written."
        }
        if case SaveFileStore.Failure.tooLarge = error {
            return "The save is larger than OmniPlay keeps (16 MB), so it was not written."
        }
        return "OmniPlay could not write to this game's save folder."
    }

    /// `seed()` refuses a launch past `maxSeedBytes`, so a write that would take the whole store there is refused now,
    /// while the player can still be told, instead of at the next launch.
    func requireSeedRoom(for bytes: Int, replacing target: URL) throws {
        var total = bytes
        for store in kinds.flatMap(stores) {
            for (stem, size) in (try? store.keys()) ?? [] where (try? store.url(for: stem)) != target {
                total += Int(size)
            }
        }
        guard total <= Self.maxSeedBytes else { throw Failure.seedFull }
    }

    /// JSON `{"ls": {key: string}, "mz": {key: base64}}` for `__OMNIPLAY_SAVES__`.
    public func seed() throws -> String {
        var budget = Self.maxSeedBytes
        var out: [String: [String: String]] = [:]
        do {
            for kind in kinds {
                var map: [String: String] = [:]
                for store in stores(kind) {
                    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
                    AtomicFileWriter.sweepStale(in: store.directory)
                    for (stem, bytes) in try store.keys() {
                        guard bytes <= budget else {
                            throw Failure.incompleteSeed("Together they exceed the 32 MB launch limit.")
                        }
                        guard let data = try store.read(key: stem), data.count <= budget else {
                            throw Failure.incompleteSeed("A save changed or disappeared while it was being read.")
                        }
                        budget -= data.count
                        if kind.name == "ls" {
                            guard let key = SaveKey.decodeWebStorage(stem), let text = String(data: data, encoding: .utf8) else {
                                throw Failure.incompleteSeed("A web save is not valid text.")
                            }
                            map[key] = text
                        } else {
                            map[stem] = data.base64EncodedString()
                        }
                    }
                }
                out[kind.name] = map
            }
            guard let seed = try String(data: JSONEncoder().encode(out), encoding: .utf8) else {
                throw Failure.incompleteSeed("The save data could not be prepared for the game.")
            }
            return seed
        } catch let error as Failure {
            throw error
        } catch {
            log(.error, "seed failed: \(error)")
            throw Failure.incompleteSeed("A save file or folder could not be read.")
        }
    }

    private func log(_ level: OSLogType, _ message: String) { OPLog.log(.save, level, message, session: session) }
}
