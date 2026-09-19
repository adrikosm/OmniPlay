import GameCore
import GameDetection
import GameStore
import SaveKit
import SwiftUI

/// A game's saves and snapshots: back up now, restore any snapshot (replace, or add into free slots).
struct SaveBackupsView: View {
    @Environment(AppModel.self) private var model
    let game: GameRecord
    @State private var slots: [(key: String, bytes: Int64)] = []
    @State private var snapshots: [(directory: URL, manifest: SaveSnapshot)] = []
    @State private var pendingRestore: (URL, RestoreMode)?
    @State private var message: String?
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
