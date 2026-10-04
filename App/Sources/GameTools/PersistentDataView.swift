import GameCore
import GameDetection
import GameImport
import GameStore
import GameTools
import RuntimeCore
import SaveKit
import SwiftUI

/// The data a game keeps between saves (settings, global unlocks, Ren'Py `persistent`), store by store: export,
/// back up, restore from a snapshot, reset, and inspect. Every change takes a snapshot first; nothing here touches
/// save slots. Writing is for when the game is not running; inspecting live values needs it running.
struct PersistentDataView: View {
    @Environment(AppModel.self) private var model
    let game: GameRecord
    let running: Bool
    let tools: MutationEngine?
    @State private var stores: [PersistentStoreInfo] = []
    @State private var snapshots: [(directory: URL, manifest: SaveSnapshot)] = []
    @State private var message: String?
    @State private var busy = false
    @State private var exportURL: URL?
    @State private var pendingReset: PersistentStoreInfo?
    @State private var restoring: PersistentStoreInfo?

    private var location: SaveLocation { SaveLocation.forGame(game.id, paths: model.paths) }
    private var identityHash: String { AppModel.identityHash(for: game.id, paths: model.paths) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s4) {
                Text(running
                    ? "Kept separately from saves. Values can be inspected now; back up, restore and reset once you leave the game."
                    : "Kept separately from saves. OmniPlay takes a snapshot before every change.")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    .rise(0)
                GlassSection {
                    if stores.isEmpty {
                        ListRow(title: "This game keeps nothing outside its saves", dimmed: true)
                    }
                    ForEach(stores) { store in storeRow(store) }
                }
                .frame(maxWidth: 600)
                .rise(1)
                if let exportURL {
                    ShareLink(item: exportURL) { Label("Share export", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.secondary)
                }
                if let message {
                    Text(message).font(.footnote).foregroundStyle(Theme.textSecondary).transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s3)
            .animation(Theme.quick, value: message)
        }
        .canvas()
        .navigationTitle("Persistent data")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .confirmationDialog(
            "Reset \(pendingReset?.kind.title ?? "")?",
            isPresented: $pendingReset.isPresent(),
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                if let store = pendingReset {
                    Task { await reset(store) }
                }
            }
        } message: {
            Text("The game starts with this data empty next time. A snapshot keeps the current data.")
        }
        .centeredSheet(isPresented: $restoring.isPresent(), width: 400) { close in
            if let store = restoring {
                RestorePicker(
                    snapshots: snapshots.filter { snap in snap.manifest.entries.contains { store.kind.owns($0.relativePath) } },
                    close: close
                ) { dir in
                    Task { await restore(store, from: dir) }
                }
            }
        }
    }

    /// Icon, name, "1 file · 1 byte · 23 Sep, 9:06" (or greyed "Nothing saved yet"), a tap to inspect where that
    /// works, and ••• for back up, restore, export and reset.
    private func storeRow(_ store: PersistentStoreInfo) -> some View {
        let summary = store.isPresent
            ? "\(store.files) file\(store.files == 1 ? "" : "s") · \(store.bytes.formatted(.byteCount(style: .file)))"
            + (store.modifiedAt.map { " · \($0.dayAndTime)" } ?? "")
            : "Nothing saved yet"
        return HStack(spacing: 0) {
            inspectLink(store) {
                ListRow(
                    icon: store.kind == .webLocalStorage ? "internaldrive" : "archivebox",
                    title: store.kind.title,
                    subtitle: summary,
                    minHeight: 62,
                    dimmed: !store.isPresent
                )
            }
            Menu {
                Button("Back up now", systemImage: "archivebox") { Task { await backUp() } }
                    .disabled(!store.isPresent || running)
                Button("Restore…", systemImage: "arrow.uturn.backward") { withTransaction(\.disablesAnimations, true) { restoring = store }
                }
                .disabled(running)
                Button("Export", systemImage: "square.and.arrow.up") { Task { await export(store) } }
                    .disabled(!store.isPresent)
                Divider()
                Button("Reset", systemImage: "exclamationmark.triangle", role: .destructive) { pendingReset = store }
                    .disabled(store.resettablePaths.isEmpty || running)
            } label: {
                Image(systemName: "ellipsis").font(.footnote.weight(.bold)).foregroundStyle(Theme.textPrimary)
                    .frame(width: 30, height: 30).background(Theme.fill, in: .circle)
                    .frame(width: 44, height: 44)
            }
            .tint(Theme.textPrimary)
            .padding(.trailing, Theme.s3)
            .accessibilityLabel("Actions for \(store.kind.title)")
        }
        .accessibilityIdentifier("persistentData.\(store.kind.rawValue)")
    }

    /// Ren'Py's `persistent` opens in Variables while the game runs; web storage opens in the editor.
    @ViewBuilder
    private func inspectLink(_ store: PersistentStoreInfo, @ViewBuilder label: () -> some View) -> some View {
        if store.kind == .renpyPersistent, running, let tools, tools.capabilities.contains(.persistent) {
            NavigationLink { VariablesView(tools: tools, categories: [.persistent]) } label: { label() }.buttonStyle(.row)
        } else if store.kind == .webLocalStorage || store.kind == .mvGlobalConfig, store.isPresent {
            NavigationLink {
                WebStorageEditor(location: location, identityHash: identityHash, paths: store.paths, writable: !running)
            } label: { label() }
                .buttonStyle(.row)
        } else {
            label()
        }
    }

    private func reload() async {
        let location = location
        let kinds = SaveStrategy.forEngine(game.engine, generation: game.generation).persistentStores
            .compactMap { PersistentStoreKind(rawValue: $0.rawValue) }
        (stores, snapshots) = await Task.detached {
            (PersistentStoreRegistry.stores(location: location, kinds: kinds), SaveVault.snapshots(location: location))
        }.value
    }

    private func backUp() async {
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

    private func reset(_ store: PersistentStoreInfo) async {
        pendingReset = nil
        do {
            try await PersistentStoreRegistry.reset(store, location: location, identityHash: identityHash)
            message = "\(store.kind.title) reset. The snapshot taken first brings it back."
        } catch {
            message = "Nothing was reset: \(error.localizedDescription)"
        }
        await reload()
    }

    private func restore(_ store: PersistentStoreInfo, from snapshot: URL) async {
        do {
            try await PersistentStoreRegistry.restore(store, from: snapshot, location: location, identityHash: identityHash)
            message = "\(store.kind.title) restored."
        } catch {
            message = "Nothing was restored: \(error.localizedDescription)"
        }
        await reload()
    }

    /// The store's files, as they sit under `Saves/`, in one ZIP.
    private func export(_ store: PersistentStoreInfo) async {
        let (location, paths, exports) = (location, store.paths, model.paths.exportsRoot)
        let name = "\(game.title)-\(store.kind.rawValue).zip".replacingOccurrences(of: "/", with: "-")
        do {
            exportURL = try await Task.detached {
                let staging = location.root.appending(path: ".export-\(UUID().uuidString)", directoryHint: .isDirectory)
                defer { try? FileManager.default.removeItem(at: staging) }
                for path in paths {
                    let target = staging.appending(path: path)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: location.root.appending(path: path), to: target)
                }
                try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
                let destination = exports.appending(path: name)
                try? FileManager.default.removeItem(at: destination)
                try ArchiveWriter().zip(directory: staging, to: destination, extras: [])
                return destination
            }.value
            message = "Exported \(store.kind.title)."
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
    }
}
