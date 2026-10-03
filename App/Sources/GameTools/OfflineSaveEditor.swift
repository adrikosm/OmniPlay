import Diagnostics
import GameStore
import GameTools
import RuntimeCore
import SaveKit
import SwiftUI

/// An RPG Maker MV/MZ save edited while the game is not running: the Variables editor over the decoded save, with
/// undo, and "Save changes" writing it back through the safety pipeline (snapshot, staged write, decode check, swap).
struct OfflineSaveEditor: View {
    @Environment(AppModel.self) private var model
    let game: GameRecord
    let slot: SaveSlotFile
    let identityHash: String
    let onSaved: () -> Void
    @State private var tools: MutationEngine?
    @State private var inspector: OfflineSaveInspector?
    @State private var problem: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    static let categories: [StateCategory] = [.variables, .switches, .items, .weapons, .armors, .system]

    var body: some View {
        NavigationStack {
            Group {
                if let tools {
                    VariablesView(tools: tools, categories: Self.categories, editingSave: true, title: "Editing \(slot.displayName)")
                } else if let problem {
                    Text(problem).font(.subheadline).foregroundStyle(Theme.danger).padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity).canvas()
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).canvas()
                }
            }
            .navigationTitle("Editing \(slot.displayName)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.buttonStyle(.link).fixedSize()
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .buttonStyle(PillButtonStyle(kind: .primary, height: 36))
                        .fixedSize()
                        .disabled(tools?.records.isEmpty ?? true || saving)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .preferredColorScheme(.dark)
        .task { await open() }
    }

    private func open() async {
        let (url, root) = (slot.url, model.paths.tier(.original, for: game.id))
        do {
            let (document, names) = try await Task.detached {
                try (RPGMakerSaveDocument(contentsOf: url), RPGMakerNames.load(gameRoot: root))
            }.value
            let inspector = OfflineSaveInspector(document: document, names: names)
            self.inspector = inspector
            tools = MutationEngine(inspector: inspector)
        } catch {
            problem = (error as? RPGMakerSaveDocument.Failure)?.description
                ?? "This save could not be opened: \(error.localizedDescription)"
        }
    }

    private func save() async {
        guard let inspector else { return }
        saving = true
        defer { saving = false }
        do {
            try await Self.commit(
                inspector,
                to: slot.url,
                location: SaveLocation.forGame(game.id, paths: model.paths),
                identityHash: identityHash
            )
            onSaved()
            dismiss()
        } catch {
            problem = "Nothing was changed: \(error.localizedDescription)"
            tools = nil
        }
    }

    /// Snapshot, write the re-encoded save to a staged copy, check that the copy decodes and passes the validator,
    /// then swap it in; any failure leaves the original in place.
    static func commit(_ inspector: OfflineSaveInspector, to file: URL, location: SaveLocation, identityHash: String) async throws {
        let data = try inspector.document.encoded()
        try await SafePersistTransaction(location: location, identityHash: identityHash).run(
            targets: [file],
            reason: .beforeEdit,
            mutate: { staging in try data.write(to: staging.url(for: file), options: .atomic) },
            validate: { staging in
                let staged = staging.url(for: file)
                _ = try RPGMakerSaveDocument(contentsOf: staged)
                guard SaveValidator.validate(file: staged, family: .webLocalStorage).isAcceptable else {
                    throw RPGMakerSaveDocument.Failure.notASave("the rewritten save does not validate")
                }
            }
        )
        OPLog.log(.save, .info, "offline edit written to \(file.lastPathComponent) (\(data.count) bytes)")
    }
}

#if DEBUG
    extension AppModel {
        /// `--debug-edit-save gold=4242,var1=7,item1=5`: edits the first game's first MV/MZ slot through the offline
        /// editor's own path (MutationEngine over OfflineSaveInspector, then `commit`), before it opens.
        func debugEditSave(_ game: GameRecord) async {
            guard let spec = DebugLaunch.value(for: "--debug-edit-save") else { return }
            let location = SaveLocation.forGame(game.id, paths: paths)
            let editable = SaveSlotFile.list(in: location.slots).filter(\.isOfflineEditable)
            // Slot 1 (the probe project's round-trip slot) when there is one; the leave-game autosave is newer.
            guard let slot = editable.first(where: { $0.displayName.hasSuffix("File1") || $0.displayName.hasSuffix(".file1") }) ?? editable
                .first,
                let document = try? RPGMakerSaveDocument(contentsOf: slot.url) else {
                return OPLog.log(.save, .info, "EDITPROBE no editable save")
            }
            let inspector = OfflineSaveInspector(
                document: document,
                names: RPGMakerNames.load(gameRoot: paths.tier(.original, for: game.id))
            )
            let tools = MutationEngine(inspector: inspector)
            for pair in spec.split(separator: ",") {
                let parts = pair.split(separator: "=")
                guard parts.count == 2, let value = Int(parts[1]) else { continue }
                let key = String(parts[0])
                let target: StateTarget? = switch key {
                case "gold": .gold
                case let k where k.hasPrefix("var"): Int(k.dropFirst(3)).map { .variable($0) }
                case let k where k.hasPrefix("item"): Int(k.dropFirst(4)).map { .item(kind: .item, id: $0) }
                default: nil
                }
                guard let target else { continue }
                let result = await tools.apply(.setValue(.int(value)), to: target)
                OPLog.log(.save, .info, "EDITPROBE \(key): \(result.result.rawValue) \(result.oldValue) → \(result.effectiveValue)")
            }
            do {
                let hash = Self.identityHash(for: game.id, paths: paths)
                try await OfflineSaveEditor.commit(inspector, to: slot.url, location: location, identityHash: hash)
                OPLog.log(.save, .info, "EDITPROBE committed \(slot.displayName)")
            } catch {
                OPLog.log(.save, .error, "EDITPROBE commit failed: \(error)")
            }
        }
    }
#endif
