import GameCore
import GameDetection
import GameImport
import GameStore
import GameTools
import RuntimeCore
import SaveKit
import SwiftUI

/// Restore a snapshot: a short list of the snapshots that hold this data (newest first) as radio rows, then Cancel
/// and Restore.
struct RestorePicker: View {
    let snapshots: [(directory: URL, manifest: SaveSnapshot)]
    let close: () -> Void
    let onPick: (URL) -> Void
    @State private var picked: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: "Restore a snapshot", close: close)
            if snapshots.isEmpty {
                Text("No snapshot holds this data yet.").font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            VStack(spacing: Theme.s2) {
                ForEach(snapshots.prefix(6), id: \.directory) { snap in
                    RadioRow(
                        title: snap.manifest.timestamp.dayAndTime,
                        subtitle: SaveBackupsView.label(snap.manifest.provenance.origin) + " · "
                            + "\(snap.manifest.entries.count) file\(snap.manifest.entries.count == 1 ? "" : "s")",
                        selected: (picked ?? snapshots.first?.directory) == snap.directory
                    ) { picked = snap.directory }
                }
            }
            HStack(spacing: 10) {
                Button { close() } label: { Text("Cancel").frame(maxWidth: .infinity) }.buttonStyle(.secondary)
                Button {
                    if let dir = picked ?? snapshots.first?.directory {
                        onPick(dir)
                    }
                    close()
                } label: { Text("Restore").frame(maxWidth: .infinity) }
                    .buttonStyle(.primary)
                    .disabled(snapshots.isEmpty)
            }
        }
    }
}

/// Web storage keys as text: RPG Maker MV's LZString-packed JSON is shown and saved unpacked-and-repacked, anything
/// else as it is. JSON is laid out one value per line to read and must still parse before it is written; every write
/// goes through the safety pipeline. The system text view does the scrolling, Find and Replace; Copy takes it all.
/// While the game runs, saves and deletes go through its page (`live`), so the game sees them at once and never writes
/// its old copy back over them.
struct WebStorageEditor: View {
    let location: SaveLocation
    let identityHash: String
    let paths: [String]
    let writable: Bool
    var live: (any WebStorageWriting)?
    @State private var entries: [Entry] = []
    @State private var selected: String?
    @State private var text = ""
    @State private var isValid = true
    @State private var finding = false
    @State private var message: String?
    @State private var failed = false
    @State private var saving = false
    @State private var deleting: [Entry] = []

    struct Entry: Identifiable, Hashable {
        let path: String
        let key: String
        var text: String
        /// As loaded, for Revert and "edited".
        var original: String
        let packed: Bool
        let json: Bool
        /// When the game last wrote it, to list the newest saves first.
        let modified: Date
        var id: String { path }
    }

    private var current: Entry? { entries.first { $0.id == selected } }

    var body: some View {
        Split(spacing: Theme.s4, leadingWidth: 200) {
            ScrollView {
                GlassSection {
                    ForEach(entries) { entry in
                        Button { pick(entry.id) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.key).font(.system(.subheadline, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                                        .lineLimit(1).truncationMode(.middle)
                                    Text(entry.modified.dayAndTime).font(.caption).foregroundStyle(Theme.textTertiary)
                                }
                                Spacer(minLength: 0)
                                if entry.text != entry.original {
                                    Circle().fill(Theme.accent).frame(width: 6, height: 6).accessibilityLabel("Edited")
                                }
                            }
                            .padding(.horizontal, Theme.s4)
                            .frame(minHeight: 46)
                            .background(entry.id == selected ? Theme.fill : .clear)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.row)
                        .accessibilityAddTraits(entry.id == selected ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
            .rise(0)
        } trailing: {
            VStack(alignment: .leading, spacing: Theme.s2) {
                ValueTextView(text: $text, editable: writable, finding: $finding)
                    .padding(Theme.s2)
                    .frame(minHeight: 180, maxHeight: .infinity)
                    .glass(radius: Theme.listRadius)
                    .accessibilityLabel(current?.key ?? "Value")
                HStack(alignment: .firstTextBaseline) {
                    Text(status).font(.footnote).foregroundStyle(failed || !isValid ? Theme.danger : Theme.textSecondary)
                    Spacer()
                    if let current, text != current.original, writable {
                        Button("Revert") { text = current.original }.buttonStyle(.link)
                    }
                }
                .padding(.horizontal, Theme.s1)
            }
            .rise(1)
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s3)
        .canvas()
        .navigationTitle("Web storage")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Find", systemImage: "magnifyingglass") { finding.toggle() }
                Button("Copy all", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = text
                    message = "Copied \(current?.key ?? "the value")."
                }
                // Always in the group: an item added once the keys have loaded was not drawn until the next edit.
                if writable {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        if let current {
                            deleting = entries.filter { Self.saveGroup($0.key) == Self.saveGroup(current.key) }
                        }
                    }
                }
            }
            if writable {
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .buttonStyle(PillButtonStyle(kind: .primary, height: 36))
                        .fixedSize()
                        .disabled(saving || current.map { text == $0.original } ?? true || !isValid)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .task { await loadAll() }
        .confirmationDialog(
            "Delete \(deleting.count == 1 ? "this key" : "these \(deleting.count) keys")?",
            isPresented: Binding(get: { !deleting.isEmpty }, set: {
                if !$0 {
                    deleting = []
                }
            }),
            titleVisibility: .visible
        ) {
            // Taken now: closing the dialog empties `deleting` before a task would read it.
            Button("Delete", role: .destructive) {
                let group = deleting
                Task { await delete(group) }
            }
        } message: {
            Text(deleting.map(\.key).joined(separator: "\n") + "\n\nA snapshot is taken first, so Restore can bring them back.")
        }
        .onChange(of: text) { _, new in
            if let i = entries.firstIndex(where: { $0.id == selected }) {
                entries[i].text = new
            }
            message = nil
            isValid = current?.json != true || (try? JSONSerialization.jsonObject(with: Data(new.utf8), options: .fragmentsAllowed)) != nil
        }
    }

    private var status: String {
        if let message {
            return message
        }
        guard let current else { return "" }
        let kind = current.json ? (isValid ? "Valid JSON" : "Not valid JSON") : "Text"
        let edited = text != current.original ? " · edited" : ""
        guard writable else { return kind + " · read only while the game runs" }
        return kind + edited + (live == nil ? "" : " · live")
    }

    // MARK: Loading and saving

    private func pick(_ id: String) {
        guard id != selected, let entry = entries.first(where: { $0.id == id }) else { return }
        selected = id
        text = entry.text
    }

    private func loadAll() async {
        let (paths, location) = (paths, location)
        entries = await Task.detached { Self.load(paths, from: location) }.value
        if let first = entries.first {
            selected = first.id
            text = first.text
        }
    }

    /// Every key, unpacked and laid out, off the main thread: a Harlowe save is tens of kilobytes of history.
    nonisolated static func load(_ paths: [String], from location: SaveLocation) -> [Entry] {
        // A save's keys together (the save itself first, then its meta, filename and metadata twins), and the save
        // written most recently at the top.
        let entries: [Entry] = paths.compactMap { path in
            let url = location.root.appending(path: path)
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let stem = url.deletingPathExtension().lastPathComponent
            let key = SaveKey.decodeWebStorage(stem) ?? stem
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if let unpacked = LZString.decompressFromBase64(raw), !unpacked.isEmpty, let pretty = Self.pretty(unpacked) {
                return Entry(path: path, key: key, text: pretty, original: pretty, packed: true, json: true, modified: modified)
            }
            if let pretty = Self.pretty(raw) {
                return Entry(path: path, key: key, text: pretty, original: pretty, packed: false, json: true, modified: modified)
            }
            return Entry(path: path, key: key, text: raw, original: raw, packed: false, json: false, modified: modified)
        }
        let latest = Dictionary(entries.map { (saveGroup($0.key), $0.modified) }, uniquingKeysWith: max)
        return entries.sorted { a, b in
            let (ga, gb) = (saveGroup(a.key), saveGroup(b.key))
            guard ga == gb else {
                let (ta, tb) = (latest[ga] ?? .distantPast, latest[gb] ?? .distantPast)
                return ta != tb ? ta > tb : ga.localizedStandardCompare(gb) == .orderedAscending
            }
            if (a.key == ga) != (b.key == gb) {
                return a.key == ga
            }
            return a.key.localizedStandardCompare(b.key) == .orderedAscending
        }
    }

    /// JSON laid out one value per line (keys sorted), or nil when the text is not JSON.
    private nonisolated static func pretty(_ string: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(string.utf8), options: .fragmentsAllowed),
              let data = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
              )
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The keys that make up one save: Harlowe keeps `(Saved Game …) name` with `Filename` and `Metadata` twins, and
    /// games add a `… meta` key beside a slot. Deleting one alone leaves the game listing a save it cannot load.
    nonisolated static func saveGroup(_ key: String) -> String {
        let base = key.hasSuffix(" meta") ? String(key.dropLast(5)) : key
        return base.replacingOccurrences(of: "(Saved Game Filename ", with: "(Saved Game ")
            .replacingOccurrences(of: "(Saved Game Metadata ", with: "(Saved Game ")
    }

    private func delete(_ group: [Entry]) async {
        deleting = []
        do {
            _ = try await SaveVault.snapshot(location: location, identityHash: identityHash, reason: .beforeEdit)
            for entry in group {
                if let live {
                    try await live.writeStorage(entry.key, nil)
                } else {
                    try FileManager.default.removeItem(at: location.root.appending(path: entry.path))
                }
            }
            entries.removeAll { group.contains($0) }
            selected = entries.first?.id
            text = entries.first?.text ?? ""
            failed = false
            message = "Deleted \(group.count) key\(group.count == 1 ? "" : "s"). The snapshot taken first keeps them."
        } catch {
            failed = true
            message = "Nothing more was deleted: \(error.localizedDescription)"
        }
    }

    private func save() async {
        guard let entry = current else { return }
        if entry.json, !isValid {
            failed = true
            message = "\(entry.key) is no longer valid JSON; nothing was saved."
            return
        }
        saving = true
        defer { saving = false }
        let value = entry.packed ? LZString.compressToBase64(entry.text) : entry.text
        let file = location.root.appending(path: entry.path)
        do {
            if let live {
                _ = try await SaveVault.snapshot(location: location, identityHash: identityHash, reason: .beforeEdit)
                try await live.writeStorage(entry.key, value)
            } else {
                try await SafePersistTransaction(location: location, identityHash: identityHash)
                    .run(targets: [file], reason: .beforeEdit) { staging in
                        try Data(value.utf8).write(to: staging.url(for: file), options: .atomic)
                    }
            }
            failed = false
            if let i = entries.firstIndex(where: { $0.id == entry.id }) {
                (entries[i].text, entries[i].original) = (entry.text, entry.text)
            }
            message = live == nil ? "Saved \(entry.key). The snapshot taken first keeps the old value."
                : "Saved \(entry.key) into the running game; load that save in the game to play it."
        } catch {
            failed = true
            message = "Nothing was saved: \(error.localizedDescription)"
        }
    }
}

/// The value pane: a UITextView scrolls and edits long text itself and brings its own find and replace bar. Smart
/// quotes and dashes are off, since a curled quote breaks JSON. Read only while the game runs, still selectable.
private struct ValueTextView: UIViewRepresentable {
    @Binding var text: String
    let editable: Bool
    @Binding var finding: Bool

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textColor = UIColor(Theme.textPrimary)
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.spellCheckingType = .no
        view.isFindInteractionEnabled = true
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.text = $text
        view.isEditable = editable
        if view.text != text {
            view.text = text
        }
        if finding {
            DispatchQueue.main.async {
                finding = false
                view.findInteraction?.presentFindNavigator(showingReplace: editable)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textViewDidChange(_ view: UITextView) { text.wrappedValue = view.text }
    }
}
