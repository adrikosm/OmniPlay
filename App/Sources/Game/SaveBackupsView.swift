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
    /// The game is open: its page keeps the storage it loaded, so changes made here would be lost or clash with its saves.
    let running: Bool
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
    @State var mirrorChanges = 0
    @State var copiedPath = false

    var location: SaveLocation { SaveLocation.forGame(game.id, paths: model.paths) }
    var identityHash: String { AppModel.identityHash(for: game.id, paths: model.paths) }

    var strategy: SaveStrategy { SaveStrategy.forEngine(game.engine, generation: game.generation) }
    /// A plain HTML5 game keeps every save in its web storage, so it has saves without any slot.
    var hasSaves: Bool { !slots.isEmpty || stores.contains(where: \.isPresent) }

    var body: some View {
        ScrollView {
            Split(spacing: Theme.s6, leadingWidth: 430) {
                VStack(alignment: .leading, spacing: Theme.s4) {
                    GlassSection("Saves") {
                        if slots.isEmpty {
                            ListRow(title: hasSaves ? "Saved in the game's own data, below" : "Nothing saved yet", dimmed: true)
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
                    filesRow.rise(1)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { actions }
                        VStack(alignment: .leading, spacing: 10) { actions }
                    }
                    .rise(2)
                    if running {
                        Text("Close the game to restore, import or change saves. Back up and Export still work.")
                            .font(.footnote).foregroundStyle(Theme.textSecondary).padding(.horizontal, Theme.s1)
                    }
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(Theme.textSecondary).padding(.horizontal, Theme.s1)
                    }
                }
            } trailing: {
                VStack(alignment: .leading, spacing: Theme.s6) {
                    GlassSection(
                        "Snapshots",
                        footer: "Taken before every launch, change and restore. The newest few of each kind are kept, "
                            + "and manual ones and any that hold a deleted save always."
                    ) {
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
                                        .disabled(busy || running || store.resettablePaths.isEmpty)
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
                model.reindexSaves(game.id)
                Task { await reload() }
            }
        }
        .centeredSheet(isPresented: $details.isPresent(), width: 560) { close in
            if let slot = details {
                SaveSlotDetails(
                    slot: slot, preview: previews[slot.id], family: strategy.family,
                    close: close,
                    onEdit: slot.isOfflineEditable && !running ? { close(); editing = slot } : nil,
                    onDuplicate: duplicateName(for: slot) != nil && !running ? { close(); Task { await duplicate(slot) } } : nil,
                    onDelete: running ? nil : { close(); pendingDelete = slot }
                )
            }
        }
        .confirmationDialog(
            "Delete \(pendingDelete.map { previews[$0.id]?.title ?? $0.displayName } ?? "this save")?",
            isPresented: $pendingDelete.isPresent(),
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
            isPresented: $pendingReset.isPresent(),
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
        .task {
            await reload()
            // Changes made in the Files app are asked about here too; while the game runs they wait for its next launch.
            if !running {
                mirrorChanges = model.mirrorChanges(for: game).count
                if mirrorChanges == 0 {
                    await model.mirrorSaves(game.id, title: game.title)
                }
            }
        }
        .centeredSheet(isPresented: Binding(get: { mirrorChanges > 0 }, set: {
            if !$0 {
                mirrorChanges = 0
            }
        })) { close in
            SavesChangedSheet(game: game, changes: mirrorChanges, close: close) {
                close()
                Task { await reload() }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.zip, .folder, .data]) { result in
            if case let .success(url) = result {
                pickedImport = url
            }
        }
        .confirmationDialog(
            "Where should the saves go?",
            isPresented: $pickedImport.isPresent(),
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
            isPresented: $pendingRestore.isPresent(),
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

    /// Where the Files app shows this game's saves, and a way there.
    var filesRow: some View {
        let path = "On My iPhone › OmniPlay › Titles › Saves › " + model.saveMirror.folder(for: game.id, title: game.title)
            .lastPathComponent
        return GlassSection {
            HStack(spacing: Theme.s3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("In the Files app").font(.subheadline).foregroundStyle(Theme.textPrimary)
                    Text(path).font(Theme.mono).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .contextMenu {
                            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = path }
                        }
                }
                Spacer(minLength: Theme.s2)
                Button("Show") { showInFiles() }.buttonStyle(.link)
            }
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s2)
            .frame(minHeight: Theme.rowHeight)
        }
    }

    /// Opens Files at the folder, written first so it is there to open.
    func showInFiles() {
        Task {
            await model.mirrorSaves(game.id, title: game.title)
            let folder = model.saveMirror.folder(for: game.id, title: game.title)
            if let url = URL(string: "shareddocuments://" + folder.path(percentEncoded: true)) {
                await UIApplication.shared.open(url)
            }
        }
    }

    @ViewBuilder var actions: some View {
        Button { Task { await backUpNow() } } label: { Text("Back up now") }
            .buttonStyle(.primary)
            .disabled(busy || !hasSaves)
        if let exportURL {
            ShareLink(item: exportURL) { Label("Share", systemImage: "square.and.arrow.up") }
                .buttonStyle(.secondary)
        } else {
            Button { Task { await exportSaves() } } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .buttonStyle(.secondary)
                .disabled(busy || !hasSaves)
        }
        Button { showImporter = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
            .buttonStyle(.secondary)
            .disabled(busy || running)
    }

    @ViewBuilder func slotMenu(_ slot: SaveSlotFile) -> some View {
        if !running {
            if slot.isOfflineEditable {
                Button("Edit", systemImage: "slider.horizontal.3") { editing = slot }
            }
            if duplicateName(for: slot) != nil {
                Button("Duplicate", systemImage: "plus.square.on.square") { Task { await duplicate(slot) } }
            }
            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = slot }
        }
    }

    func snapshotRow(_ dir: URL, _ snap: SaveSnapshot) -> some View {
        ListRow(
            title: snap.timestamp.dayAndTime,
            subtitle: "\(Self.label(snap.provenance.origin)) · \(snap.entries.count) file\(snap.entries.count == 1 ? "" : "s")"
        ) {
            Menu {
                Button("Replace current saves", systemImage: "arrow.uturn.backward") { pendingRestore = (dir, .replace) }
                Button("Add into free slots", systemImage: "square.stack.3d.up") {
                    pendingRestore = (dir, .stackIntoFreeSlots(slotPattern: strategy.slotPattern))
                }
            } label: {
                Text("Restore").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent).frame(minWidth: 44, minHeight: 44)
            }
            .tint(Theme.textPrimary)
            .disabled(busy || running)
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
