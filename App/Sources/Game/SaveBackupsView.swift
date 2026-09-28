import GameCore
import GameDetection
import GameStore
import SaveKit
import SwiftUI
import UniformTypeIdentifiers

/// A game's saves and snapshots: back up now, restore any snapshot (replace, or add into free slots).
struct SaveBackupsView: View {
    @Environment(AppModel.self) var model
    let game: GameRecord
    @State var slots: [SaveSlotFile] = []
    @State var previews: [String: SavePreview] = [:]
    @State var details: SaveSlotFile?
    @State var pendingDelete: SaveSlotFile?
    @State var editing: SaveSlotFile?
    @State var snapshots: [(directory: URL, manifest: SaveSnapshot)] = []
    @State var pendingRestore: (URL, RestoreMode)?
    @State var message: String?
    @State var exportURL: URL?
    @State var showImporter = false
    @State var pendingImport: (URL, SaveTransfer.Collision)?
    @State var importWarnings: [String] = []
    @State var pickedImport: URL?
    @State var stores: [PersistentStoreInfo] = []
    @State var pendingReset: PersistentStoreInfo?
    @State var busy = false

    var location: SaveLocation { SaveLocation.forGame(game.id, paths: model.paths) }
    var identityHash: String {
        AppModel.snapshot(for: game.id, paths: model.paths)?.report.descriptor.identityHash ?? game.id.description
    }

    var slotPattern: String? { SaveStrategy.forEngine(game.engine, generation: game.generation).slotPattern }

    var body: some View {
        ScrollView {
            Split(spacing: Theme.s6, leadingWidth: 430) {
                VStack(alignment: .leading, spacing: Theme.s4) {
                    GlassSection("Saves") {
                        if slots.isEmpty {
                            ListRow(title: "Nothing saved yet", dimmed: true)
                        }
                        ForEach(slots) { slot in
                            Button { withTransaction(\.disablesAnimations, true) { details = slot } } label: {
                                SaveSlotRow(slot: slot, preview: previews[slot.id])
                            }
                            .buttonStyle(.row)
                            .contextMenu { slotMenu(slot).tint(Theme.textPrimary) }
                        }
                    }
                    .rise(0)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { actions }
                        VStack(alignment: .leading, spacing: 10) { actions }
                    }
                    .rise(1)
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(Theme.textSecondary).padding(.horizontal, Theme.s1)
                    }
                }
            } trailing: {
                VStack(alignment: .leading, spacing: Theme.s6) {
                    GlassSection("Snapshots", footer: "Taken before every launch and every restore. Restoring never deletes a snapshot.") {
                        if snapshots.isEmpty {
                            ListRow(title: "No snapshots yet", dimmed: true)
                        }
                        ForEach(snapshots, id: \.manifest.id) { snap in
                            snapshotRow(snap.directory, snap.manifest)
                        }
                    }
                    if !stores.isEmpty {
                        GlassSection(
                            "Settings and progress data",
                            footer: "Kept apart from the save slots. Resetting takes a snapshot first."
                        ) {
                            ForEach(stores) { store in
                                ListRow(title: store.kind.title, subtitle: Self.storeSummary(store)) {
                                    Button("Reset", role: .destructive) { pendingReset = store }
                                        .buttonStyle(.link)
                                        .disabled(busy || !store.isPresent)
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("persistentStore.\(store.kind.rawValue)")
                            }
                        }
                    }
                }
                .rise(2)
            }
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s3)
        }
        .scrollBounceBehavior(.basedOnSize)
        .sheet(item: $editing) { slot in
            OfflineSaveEditor(game: game, slot: slot, identityHash: identityHash) {
                message = "Save changed. The snapshot taken first keeps the old one."
                Task { await reload() }
            }
        }
        .centeredSheet(isPresented: Binding(get: { details != nil }, set: {
            if !$0 {
                details = nil
            }
        }), width: 560) { close in
            if let slot = details {
                SaveSlotDetails(
                    slot: slot, preview: previews[slot.id], family: SaveStrategy.forEngine(game.engine, generation: game.generation).family,
                    close: close,
                    onEdit: slot.isOfflineEditable ? { close(); editing = slot } : nil,
                    onDuplicate: duplicateName(for: slot) != nil ? { close(); Task { await duplicate(slot) } } : nil,
                    onDelete: { close(); pendingDelete = slot }
                )
            }
        }
        .confirmationDialog(
            "Delete \(pendingDelete.map { previews[$0.id]?.title ?? $0.displayName } ?? "this save")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: {
                if !$0 {
                    pendingDelete = nil
                }
            }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let slot = pendingDelete {
                    Task { await delete(slot) }
                }
            }
        } message: {
            Text("A snapshot is taken first, so Restore can bring it back.")
        }
        .confirmationDialog(
            "Reset \(pendingReset?.kind.title ?? "this data")?",
            isPresented: Binding(get: { pendingReset != nil }, set: {
                if !$0 {
                    pendingReset = nil
                }
            }),
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                if let store = pendingReset {
                    Task { await reset(store) }
                }
            }
        } message: {
            Text("The game starts with fresh settings next time. A snapshot keeps the current data.")
        }
        .navigationTitle("Saves and backups")
        .navigationBarTitleDisplayMode(.inline)
        .canvas()
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

    @ViewBuilder var actions: some View {
        Button { Task { await backUpNow() } } label: { Text("Back up now") }
            .buttonStyle(.primary)
            .disabled(busy || slots.isEmpty)
        if let exportURL {
            ShareLink(item: exportURL) { Label("Share", systemImage: "square.and.arrow.up") }
                .buttonStyle(.secondary)
        } else {
            Button { Task { await exportSaves() } } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .buttonStyle(.secondary)
                .disabled(busy || slots.isEmpty)
        }
        Button { showImporter = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
            .buttonStyle(.secondary)
            .disabled(busy)
    }

    @ViewBuilder func slotMenu(_ slot: SaveSlotFile) -> some View {
        if slot.isOfflineEditable {
            Button("Edit", systemImage: "slider.horizontal.3") { editing = slot }
        }
        if duplicateName(for: slot) != nil {
            Button("Duplicate", systemImage: "plus.square.on.square") { Task { await duplicate(slot) } }
        }
        Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = slot }
    }

    func snapshotRow(_ dir: URL, _ snap: SaveSnapshot) -> some View {
        ListRow(
            title: snap.timestamp.dayAndTime,
            subtitle: "\(Self.label(snap.provenance.origin)) · \(snap.entries.count) file\(snap.entries.count == 1 ? "" : "s")"
        ) {
            Menu {
                Button("Replace current saves", systemImage: "arrow.uturn.backward") { pendingRestore = (dir, .replace) }
                Button("Add into free slots", systemImage: "square.stack.3d.up") {
                    pendingRestore = (dir, .stackIntoFreeSlots(slotPattern: slotPattern))
                }
            } label: {
                Text("Restore").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent).frame(minWidth: 44, minHeight: 44)
            }
            .tint(Theme.textPrimary)
            .disabled(busy)
        }
    }

    static func storeSummary(_ store: PersistentStoreInfo) -> String {
        guard store.isPresent else { return "Empty" }
        return "\(store.files) file\(store.files == 1 ? "" : "s") · \(store.bytes.formatted(.byteCount(style: .file)))"
    }

    static func label(_ origin: SaveProvenance.Origin) -> String {
        switch origin {
        case .beforeLaunch: "Before launch"
        case .beforeEdit: "Before a change"
        case .manualSnapshot: "Manual"
        case .crash: "After crash"
        case .imported: "Imported"
        case .native: "Game"
        case .preModBackup: "Before mod"
        case .preCheatBackup: "Before cheat"
        }
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
