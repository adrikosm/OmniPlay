import Diagnostics
import Foundation
import GameCore
import OSLog
import SaveKit

/// Routes web-storage writes to `Saves/slots` and seeds the page from those files on launch.
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

    func store(_ kind: Kind) -> SaveFileStore { SaveFileStore(location: location, fileExtension: kind.fileExtension) }

    func stem(_ kind: Kind, key: String) -> String { kind.name == "ls" ? SaveKey.encodeWebStorage(key) : key }

    /// One message from the page. Rejected keys and oversized values are logged, never written.
    public func handle(op: String, kind kindName: String, key: String, value: String?) {
        guard let kind = kinds.first(where: { $0.name == kindName }) else { return log(.error, "unknown save kind \(kindName)") }
        let store = store(kind)
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
            let store = store(kind)
            var map: [String: String] = [:]
            for (stem, bytes) in store.keys() {
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
        AtomicFileWriter.sweepStale(in: location.slots)
        return (try? JSONEncoder().encode(out)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}"
    }

    private func log(_ level: OSLogType, _ message: String) { OPLog.log(.save, level, message, session: session) }
}
