import GameStore
import GameTools
import RuntimeCore
import SaveKit
import SwiftUI

/// Game Tools → Saves while playing, for engines whose saves only they can safely write (RGSS, Ren'Py; SAVE-009).
/// Edit in game: back up the saves, have the engine load the slot, change values in Variables, then have the engine
/// save back into the slot. The save is checked by loading it again and reading the last value changed; if that
/// fails, the backup taken first is put back.
struct InGameSavesView: View {
    @Environment(AppModel.self) private var model
    let game: GameRecord
    let tools: MutationEngine
    let slots: any SlotEditing
    let variables: VariablesView?
    @State private var files: [SaveSlotFile] = []
    @State private var previews: [String: SavePreview] = [:]
    @State private var loaded: SaveSlotFile?
    @State private var backup: URL?
    /// Edits made before the slot was loaded belong to the game as it was; only later ones are checked.
    @State private var editsAtLoad = 0
    @State private var busy = false
    @State private var message: String?

    private var location: SaveLocation { SaveLocation.forGame(game.id, paths: model.paths) }

    var body: some View {
        ScrollView {
            Split(spacing: Theme.s6) {
                VStack(alignment: .leading, spacing: Theme.s4) {
                    GlassSection("Saves") {
                        if files.isEmpty {
                            ListRow(title: "Nothing saved yet", dimmed: true)
                        }
                        ForEach(files) { file in
                            HStack(spacing: Theme.s3) {
                                SaveThumbnail(data: previews[file.id]?.thumbnail, width: 64, height: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(previews[file.id]?.title ?? file.displayName).font(.subheadline).foregroundStyle(Theme.textPrimary)
                                        .lineLimit(1)
                                    Text([file.modified?.dayAndTime, file.bytes.formatted(.byteCount(style: .file))].compactMap(\.self)
                                        .joined(separator: " · "))
                                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                                }
                                Spacer(minLength: Theme.s2)
                                Button("Edit in game") { Task { await load(file) } }
                                    .buttonStyle(.link)
                                    .disabled(busy || loaded != nil)
                            }
                            .padding(.horizontal, Theme.s4)
                            .frame(minHeight: 66)
                        }
                    }
                    .rise(0)
                    if let next = nextSlot {
                        Button { Task { await saveNow(into: next) } } label: { Text(busy ? "Saving…" : "Save now") }
                            .buttonStyle(.primary)
                            .disabled(busy || loaded != nil)
                            .rise(1)
                    } else {
                        Text("Every slot the game shows is in use. Edit one in game to overwrite it.")
                            .font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                }
            } trailing: {
                VStack(alignment: .leading, spacing: Theme.s4) {
                    if let loaded {
                        editing(loaded).transition(.opacity.combined(with: .move(edge: .trailing)))
                    } else {
                        Text("Save now writes the game as it is into a new slot, through the game's own save code, so its Load screen "
                            + "lists it. Edit in game loads a slot, lets you change values, then saves it back.")
                            .font(.footnote).foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, Theme.s4)
                    }
                }
                .rise(2)
            }
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s3)
            .animation(Theme.settle, value: loaded)
        }
        .scrollBounceBehavior(.basedOnSize)
        .canvas()
        .navigationTitle("Saves")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
    }

    private func editing(_ file: SaveSlotFile) -> some View {
        GlassSection(
            "Loaded in the game",
            footer: "Change what you need, then save it back into the same slot. Your saves were backed up first."
        ) {
            ListRow(title: previews[file.id]?.title ?? file.displayName, subtitle: file.modified?.dayAndTime)
            if let variables {
                NavigationLink { variables } label: {
                    ListRow(icon: "slider.horizontal.3", title: "Change values") { Chevron() }
                }
                .buttonStyle(.row)
            }
            Button { Task { await save(file) } } label: {
                ListRow(icon: "square.and.arrow.down", title: busy ? "Saving…" : "Save to this slot") {
                    if busy {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .buttonStyle(.row)
            .disabled(busy)
        }
    }

    /// The first free slot under the name the game's own Load screen reads; nil when all of them are used.
    private var nextSlot: String? {
        SlotNaming.fresh(for: game.engine, existing: Set(files.map(\.url.lastPathComponent)))
    }

    private func saveNow(into name: String) async {
        busy = true
        defer { busy = false }
        do {
            try await slots.saveSlot(file: name)
            // Ren'Py writes on its next interaction; give it a moment before listing.
            for _ in 0 ..< 10
                where !FileManager.default.fileExists(atPath: location.slots.appending(path: name).path(percentEncoded: false)) {
                try? await Task.sleep(for: .milliseconds(300))
            }
            await reload()
            message = files.contains { $0.url.lastPathComponent == name }
                ? "Saved to \(name). It is in the game's own Load screen too."
                : "The game did not write \(name)."
        } catch {
            message = "The game did not save: \(error.localizedDescription)"
        }
    }

    /// Off the main actor: a Ren'Py slot's preview inflates its screenshot out of the save's ZIP.
    private func reload() async {
        let slots = location.slots
        (files, previews) = await Task.detached {
            (SaveSlotFile.list(in: slots), SavePreviewReader.previews(in: slots, globals: []))
        }.value
    }

    private func load(_ file: SaveSlotFile) async {
        busy = true
        defer { busy = false }
        do {
            let identity = AppModel.identityHash(for: game.id, paths: model.paths)
            _ = try await SaveVault.snapshot(location: location, identityHash: identity, reason: .beforeEdit)
            backup = SaveVault.snapshots(location: location).first?.directory
            try await slots.loadSlot(file: file.url.lastPathComponent)
            // The engine loads between frames once the reply is out; give it a moment before reading values.
            try? await Task.sleep(for: .seconds(1))
            loaded = file
            editsAtLoad = tools.records.count
            message = nil
        } catch {
            message = "The game did not load it: \(error.localizedDescription)"
        }
    }

    private func save(_ file: SaveSlotFile) async {
        busy = true
        defer { busy = false }
        let before = file.url.modificationDate
        do {
            try await slots.saveSlot(file: file.url.lastPathComponent)
            // Checked the way the player would: load the slot again and read back the last change.
            guard file.url.modificationDate != before else { throw SaveEditFailure.notWritten }
            if tools.records.count > editsAtLoad, let last = tools.records.last {
                try await slots.loadSlot(file: file.url.lastPathComponent)
                try? await Task.sleep(for: .seconds(1))
                let now = try await tools.read(last.target)
                guard now == last.after else { throw SaveEditFailure.notKept }
            }
            message = "Saved and checked: the slot has your changes."
            loaded = nil
            await reload()
        } catch {
            let failure = "The save did not go through (\(error.localizedDescription))"
            message = await restoreBackup()
                ? failure + "; the backup was put back."
                : failure + ", and the backup could not be put back: close the game and restore the newest snapshot in Saves."
        }
    }

    /// True when the backup is back in place.
    private func restoreBackup() async -> Bool {
        var restored = false
        if let backup {
            let identity = AppModel.identityHash(for: game.id, paths: model.paths)
            restored = await (try? SaveVault.restore(snapshot: backup, into: location, identityHash: identity, mode: .replace)) != nil
        }
        await reload()
        return restored
    }
}

private enum SaveEditFailure: LocalizedError {
    case notWritten, notKept
    var errorDescription: String? {
        switch self {
        case .notWritten: "the engine did not write the slot"
        case .notKept: "the slot did not keep the change"
        }
    }
}

private extension URL {
    /// Read fresh from the file system each time; `resourceValues` caches per URL and would answer the old date.
    var modificationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: path(percentEncoded: false)))?[.modificationDate] as? Date
    }
}
