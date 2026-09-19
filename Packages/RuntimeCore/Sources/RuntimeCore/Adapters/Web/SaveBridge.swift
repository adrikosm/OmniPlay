import Diagnostics
import Foundation
import GameCore
import OSLog
import SaveKit

/// Routes web-storage writes to files and seeds the page from them on launch. Numbered save slots go to
/// `Saves/slots`; everything else (RPG Maker config and global data, a plain HTML5 game's whole localStorage) is a
/// persistent store under `Saves/persistent/webLocalStorage` or `webIndexedDB`, backed up and reset separately.
/// `ls` entries are UTF-8 strings under `ls.<base64url(key)>.<ext>`; `mz` entries are RPG Maker MZ deflate blobs,
/// carried as base64 and stored raw under `<key>.rmmzsave`.
public struct SaveBridge: Sendable {
    public struct Kind: Sendable, Hashable {
        public let name: String
        public let fileExtension: String
        public let binary: Bool
    }

    public let location: SaveLocation
    public let kinds: [Kind]
    private let session: SessionID?
    /// Total bytes the seed may carry into the page; larger libraries stay file-only and load lazily by the game.
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

    /// MV `RPG File<n>` and MZ `rmmzsave.<game>.file<n>` are slots; nothing else is.
    static func isSlot(kind: String, key: String) -> Bool {
        kind == "ls" ? key.wholeMatch(of: /RPG File\d+/) != nil : key.wholeMatch(of: /rmmzsave\..*\.file\d+/) != nil
    }

    func store(_ kind: Kind, key: String) -> SaveFileStore {
        let both = stores(kind)
        return Self.isSlot(kind: kind.name, key: key) ? both[0] : both[1]
    }

    func stem(_ kind: Kind, key: String) -> String { kind.name == "ls" ? SaveKey.encodeWebStorage(key) : key }

    /// One message from the page. Rejected keys and oversized values are logged, never written.
    public func handle(op: String, kind kindName: String, key: String, value: String?) {
        guard let kind = kinds.first(where: { $0.name == kindName }) else { return log(.error, "unknown save kind \(kindName)") }
        let store = store(kind, key: key)
        do {
            switch op {
            case "write":
                guard let value else { return log(.error, "write without value for \(key)") }
                guard let data = kind.binary ? Data(base64Encoded: value) : Data(value.utf8) else { return log(
                    .error,
                    "undecodable value for \(key)"
                ) }
                try store.write(data, key: stem(kind, key: key))
                log(.debug, "wrote \(kind.name) \(key) (\(data.count) bytes)")
            case "remove":
                try store.remove(key: stem(kind, key: key))
                log(.debug, "removed \(kind.name) \(key)")
            default: log(.error, "unknown save op \(op)")
            }
        } catch {
            log(.error, "save \(op) \(key) failed: \(error)")
        }
    }

    /// JSON `{"ls": {key: string}, "mz": {key: base64}}` for `__OMNIPLAY_SAVES__`.
    public func seed() -> String {
        var budget = Self.maxSeedBytes
        var out: [String: [String: String]] = [:]
        for kind in kinds {
            var map: [String: String] = [:]
            for store in stores(kind) {
                try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
                AtomicFileWriter.sweepStale(in: store.directory)
            }
            for (store, stem, bytes) in stores(kind).flatMap({ s in s.keys().map { (s, $0.key, $0.bytes) } }) {
                guard bytes <= budget,
                      let data = try? store.read(key: stem) else { log(.default, "seed skipped \(stem): over budget"); continue }
                budget -= Int(bytes)
                if kind.name == "ls" {
                    guard let key = SaveKey.decodeWebStorage(stem), let text = String(data: data, encoding: .utf8) else { continue }
                    map[key] = text
                } else {
                    map[stem] = data.base64EncodedString()
                }
            }
            out[kind.name] = map
        }
        return (try? JSONEncoder().encode(out)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}"
    }

    private func log(_ level: OSLogType, _ message: String) { OPLog.log(.save, level, message, session: session) }
}
