import Foundation
import GameCore
import GameDetection
import GameStore
import SaveKit

extension AppModel {
    /// Rebuilds `saves_meta` from the slot files so the library can show what a game has saved.
    func indexSaves(for descriptor: GameDescriptor) {
        guard let store else { return }
        let location = SaveLocation.forGame(descriptor.id, paths: paths)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: location.slots,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        )) ?? []
        let records = files.filter { !$0.lastPathComponent.hasPrefix(".") }.map { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let stem = url.deletingPathExtension().lastPathComponent
            return SaveMetaRecord(
                gameId: descriptor.id,
                slotKey: SaveKey.decodeWebStorage(stem) ?? stem,
                relPath: "Saves/slots/\(url.lastPathComponent)",
                family: descriptor.saveFamily.rawValue,
                bytes: Int64(values?.fileSize ?? 0),
                modifiedAt: values?.contentModificationDate ?? .now,
                provenanceHash: descriptor.identityHash
            )
        }
        try? store.saves.replaceAll(game: descriptor.id, with: records)
        let kinds = SaveStrategy.forEngine(descriptor.engine, generation: descriptor.generation).persistentStores
            .compactMap { PersistentStoreKind(rawValue: $0.rawValue) }
        let stores = PersistentStoreRegistry.stores(location: location, kinds: kinds).filter(\.isPresent).map {
            PersistentStoreRecord(
                gameId: descriptor.id,
                kind: $0.kind.rawValue,
                relPath: paths.stored($0.directory),
                bytes: $0.bytes,
                modifiedAt: $0.modifiedAt ?? .now
            )
        }
        try? store.persistentStores.replaceAll(game: descriptor.id, with: stores)
    }
}
