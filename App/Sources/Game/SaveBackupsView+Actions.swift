import GameCore
import GameDetection
import GameStore
import SaveKit
import SwiftUI
import UniformTypeIdentifiers

extension SaveBackupsView {
    func reload() async {
        let location = location
        let kinds = SaveStrategy.forEngine(game.engine, generation: game.generation).persistentStores
            .compactMap { PersistentStoreKind(rawValue: $0.rawValue) }
        let (slotList, previewList, snapList, storeList) = await Task.detached {
            (
                SaveSlotFile.list(in: location.slots),
                SavePreviewReader.previews(
                    in: location.slots,
                    globals: (try? FileManager.default.contentsOfDirectory(at: location.persistent, includingPropertiesForKeys: nil)) ?? []
                ),
                SaveVault.snapshots(location: location),
                PersistentStoreRegistry.stores(location: location, kinds: kinds)
            )
        }.value
        slots = slotList
        previews = previewList
        snapshots = snapList
        stores = storeList
    }

    var transfer: SaveTransfer {
        SaveTransfer(paths: model.paths, target: .init(
            id: game.id, title: game.title, engine: game.engine,
            family: SaveStrategy.forEngine(game.engine, generation: game.generation).family,
            slotPattern: slotPattern, identityHash: identityHash
        ))
    }

    func exportSaves() async {
        busy = true
        defer { busy = false }
        do {
            exportURL = try await transfer.export()
            message = "Exported to Files › OmniPlay › Saves-Export."
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
    }

    func runImport(confirmed: Bool) async {
        guard let (url, collision) = pendingImport else { return }
        pickedImport = nil
        importWarnings = []
        busy = true
        defer { busy = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            switch try await transfer.importSaves(from: url, collision: collision, confirmed: confirmed) {
            case let .installed(slots, persistent):
                let slotText = "\(slots) save\(slots == 1 ? "" : "s")"
                let settingsText = persistent > 0 ? " and \(persistent) settings file\(persistent == 1 ? "" : "s")" : ""
                message = "Imported \(slotText)\(settingsText)."
                pendingImport = nil
                model.reindexSaves(game.id)
                exportURL = nil
            case let .needsConfirmation(warnings):
                importWarnings = warnings
            case let .nothingRecognised(reasons):
                message = "Nothing imported. " + reasons.joined(separator: " ")
                pendingImport = nil
            }
        } catch {
            message = "Import failed, nothing was changed: \(error.localizedDescription)"
            pendingImport = nil
        }
        await reload()
    }

    func reset(_ store: PersistentStoreInfo) async {
        busy = true
        defer { busy = false }
        pendingReset = nil
        do {
            try await PersistentStoreRegistry.reset(store, location: location, identityHash: identityHash)
            message = "\(store.kind.title) reset."
            model.reindexSaves(game.id)
        } catch {
            message = "Reset failed, nothing was changed: \(error.localizedDescription)"
        }
        await reload()
    }

    func backUpNow() async {
        busy = true
        defer { busy = false }
        do {
            _ = try await SaveVault.snapshot(location: location, identityHash: identityHash, reason: .manualSnapshot)
            message = "Snapshot saved."
        } catch {
            message = "Backup failed: \(error.localizedDescription)"
        }
        await reload()
    }

    func duplicateName(for slot: SaveSlotFile) -> String? {
        SlotNaming.duplicateName(for: slot.id, existing: Set(slots.map(\.id)), pattern: slotPattern)
    }

    /// A copy in the next free slot: nothing existing is touched, so no snapshot is needed.
    func duplicate(_ slot: SaveSlotFile) async {
        guard let name = duplicateName(for: slot) else { return }
        do {
            try FileManager.default.copyItem(at: slot.url, to: location.slots.appending(path: name))
            message = "Copied to \(name)."
        } catch {
            message = "Could not copy: \(error.localizedDescription)"
        }
        await reload()
    }

    /// Snapshot first, then remove: the deleted save stays one Restore away.
    func delete(_ slot: SaveSlotFile) async {
        busy = true
        defer { busy = false }
        pendingDelete = nil
        do {
            _ = try await SaveVault.snapshot(location: location, identityHash: identityHash, reason: .beforeEdit)
            try FileManager.default.removeItem(at: slot.url)
            message = "Deleted. The snapshot taken just now can bring it back."
        } catch {
            message = "Nothing was deleted: \(error.localizedDescription)"
        }
        await reload()
    }

    func restore(_ dir: URL, _ mode: RestoreMode) async {
        busy = true
        defer { busy = false }
        pendingRestore = nil
        do {
            try await SaveVault.restore(snapshot: dir, into: location, identityHash: identityHash, mode: mode)
            message = "Restored."
        } catch {
            message = "Restore failed, nothing was changed: \(error.localizedDescription)"
        }
        await reload()
    }
}
