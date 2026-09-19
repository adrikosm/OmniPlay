import GameCore
import GameDetection
import GameStore
import SaveKit
import SwiftUI
import UniformTypeIdentifiers

/// A game's saves and snapshots: back up now, restore any snapshot (replace, or add into free slots).
struct SaveBackupsView: View {
    @Environment(AppModel.self) private var model
    let game: GameRecord
    @State private var slots: [(key: String, bytes: Int64)] = []
    @State private var snapshots: [(directory: URL, manifest: SaveSnapshot)] = []
    @State private var pendingRestore: (URL, RestoreMode)?
    @State private var message: String?
    @State private var exportURL: URL?
    @State private var showImporter = false
    @State private var pendingImport: (URL, SaveTransfer.Collision)?
    @State private var importWarnings: [String] = []
    @State private var pickedImport: URL?
    @State private var busy = false

    private var location: SaveLocation { SaveLocation.forGame(game.id, paths: model.paths) }
    private var identityHash: String {
        AppModel.snapshot(for: game.id, paths: model.paths)?.report.descriptor.identityHash ?? game.id.description
    }

    private var slotPattern: String? { SaveStrategy.forEngine(game.engine, generation: game.generation).slotPattern }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s6) {
                VStack(alignment: .leading, spacing: Theme.s2) {
                    Text("Saves").font(Theme.title(22)).foregroundStyle(Theme.textPrimary)
                    if slots.isEmpty {
                        Text("Nothing saved yet.").font(.footnote).foregroundStyle(Theme.textSecondary)
                    } else {
                        ForEach(slots, id: \.key) { slot in
                            HStack {
                                Text(SaveKey.decodeWebStorage(slot.key) ?? slot.key).font(.system(.footnote, design: .monospaced))
                                Spacer()
                                Text(slot.bytes.formatted(.byteCount(style: .file))).font(.caption)
                            }
                            .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .padding(Theme.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()

                Button { Task { await backUpNow() } } label: { Label("Back up now", systemImage: "plus.circle").frame(maxWidth: .infinity) }
                    .buttonStyle(LanternButtonStyle())
                    .disabled(busy || slots.isEmpty)

                HStack(spacing: Theme.s2) {
                    if let exportURL {
                        ShareLink(item: exportURL) { Label("Share export", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                    } else {
                        Button { Task { await exportSaves() } } label: {
                            Label("Export saves", systemImage: "arrow.up.doc").frame(maxWidth: .infinity)
                        }
                        .disabled(busy || slots.isEmpty)
                    }
                    Button { showImporter = true } label: { Label("Import saves", systemImage: "arrow.down.doc").frame(maxWidth: .infinity)
                    }
                    .disabled(busy)
                }
                .foregroundStyle(Theme.textPrimary)
                .frame(minHeight: 44)
                .padding(.horizontal, Theme.s3)
                .glassCard(radius: 14)

                VStack(alignment: .leading, spacing: Theme.s3) {
                    Text("Snapshots").font(Theme.title(22)).foregroundStyle(Theme.textPrimary)
                    Text("Taken before every launch and before every restore. Restoring never deletes a snapshot.")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                    if snapshots.isEmpty {
                        Text("No snapshots yet.").font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(snapshots, id: \.manifest.id) { snap in
                        snapshotRow(snap.directory, snap.manifest)
                    }
                }
                .padding(Theme.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()

                if let message {
                    Text(message).font(.footnote).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(Theme.s4)
        }
        .navigationTitle("Saves and backups")
        .navigationBarTitleDisplayMode(.inline)
        .inkScreen()
        .task { await reload() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.zip, .folder, .data]) { result in
            if case let .success(url) = result {
                pickedImport = url
            }
        }
        .confirmationDialog(
            "Where should the saves go?",
            isPresented: Binding(get: { pickedImport != nil }, set: {
                if !$0 {
                    pickedImport = nil
                }
            }),
            titleVisibility: .visible
        ) {
            Button("Replace same-numbered slots") {
                if let url = pickedImport {
                    pendingImport = (url, .replace); Task { await runImport(confirmed: false) }
                }
            }
            Button("Add into free slots") {
                if let url = pickedImport {
                    pendingImport = (url, .nextFreeSlot); Task { await runImport(confirmed: false) }
                }
            }
        }
        .confirmationDialog(
            "Import anyway?",
            isPresented: Binding(get: { !importWarnings.isEmpty }, set: {
                if !$0 {
                    importWarnings = []
                }
            }),
            titleVisibility: .visible
        ) {
            Button("Import anyway", role: .destructive) { Task { await runImport(confirmed: true) } }
        } message: {
            Text(importWarnings.joined(separator: "\n"))
        }
        .confirmationDialog(
            "Restore this snapshot?",
            isPresented: Binding(get: { pendingRestore != nil }, set: {
                if !$0 {
                    pendingRestore = nil
                }
            }),
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) {
                if let (dir, mode) = pendingRestore {
                    Task { await restore(dir, mode) }
                }
            }
        } message: {
            Text(pendingRestore?.1 == .replace
                ? "Current saves and settings are replaced. A snapshot of them is taken first."
                : "The snapshot's saves are added under free slot numbers. Current saves stay.")
        }
    }

    private func snapshotRow(_ dir: URL, _ snap: SaveSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snap.timestamp.formatted(date: .abbreviated, time: .shortened)).font(.subheadline).foregroundStyle(Theme.textPrimary)
                Text("\(Self.label(snap.provenance.origin)) · \(snap.entries.count) files").font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Menu {
                Button("Replace current saves", systemImage: "arrow.uturn.backward") { pendingRestore = (dir, .replace) }
                Button("Add into free slots", systemImage: "square.stack.3d.up") { pendingRestore = (
                    dir,
                    .stackIntoFreeSlots(slotPattern: slotPattern)
                ) }
            } label: {
                Text("Restore").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.lantern).frame(minWidth: 44, minHeight: 44)
            }
            .disabled(busy)
        }
    }

    static func label(_ origin: SaveProvenance.Origin) -> String {
        switch origin {
        case .beforeLaunch: "Before launch"
        case .beforeEdit: "Before restore"
        case .manualSnapshot: "Manual"
        case .crash: "After crash"
        case .imported: "Imported"
        case .native: "Game"
        case .preModBackup: "Before mod"
        case .preCheatBackup: "Before cheat"
        }
    }

    private func reload() async {
        let location = location
        let (slotList, snapList) = await Task.detached {
            (SaveFileStore(location: location, fileExtension: "").keysAnyExtension(), SaveVault.snapshots(location: location))
        }.value
        slots = slotList
        snapshots = snapList
    }

    private var transfer: SaveTransfer {
        SaveTransfer(paths: model.paths, target: .init(
            id: game.id, title: game.title, engine: game.engine,
            family: SaveStrategy.forEngine(game.engine, generation: game.generation).family,
            slotPattern: slotPattern, identityHash: identityHash
        ))
    }

    private func exportSaves() async {
        busy = true
        defer { busy = false }
        do {
            exportURL = try await transfer.export()
            message = "Exported to Files › OmniPlay › Saves-Export."
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
    }

    private func runImport(confirmed: Bool) async {
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

    private func backUpNow() async {
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

    private func restore(_ dir: URL, _ mode: RestoreMode) async {
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

extension SaveFileStore {
    /// Every slot file regardless of extension, for display.
    func keysAnyExtension() -> [(key: String, bytes: Int64)] {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return items.filter { !$0.lastPathComponent.hasPrefix(".") }
            .map { ($0.deletingPathExtension().lastPathComponent, Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)) }
            .sorted { $0.0 < $1.0 }
    }
}
