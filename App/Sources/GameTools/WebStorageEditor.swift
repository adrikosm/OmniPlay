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
/// goes through the safety pipeline.
struct WebStorageEditor: View {
    let location: SaveLocation
    let identityHash: String
    let paths: [String]
    let writable: Bool
    @State private var entries: [Entry] = []
    @State private var selected: String?
    @State private var text = AttributedString()
    @State private var selection = AttributedTextSelection()
    @State private var message: String?
    @State private var failed = false
    @State private var saving = false

    struct Entry: Identifiable, Hashable {
        let path: String
        let key: String
        var text: String
        /// As loaded, for Revert and "edited".
        let original: String
        let packed: Bool
        let json: Bool
        var id: String { path }
    }

    private static let font = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
    private var plain: String { String(text.characters) }
    private var current: Entry? { entries.first { $0.id == selected } }

    var body: some View {
        Split(spacing: Theme.s4, leadingWidth: 200) {
            ScrollView {
                GlassSection {
                    ForEach(entries) { entry in
                        Button { pick(entry.id) } label: {
                            HStack {
                                Text(entry.key).font(.system(.subheadline, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1).truncationMode(.middle)
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
                editor
                HStack(alignment: .firstTextBaseline) {
                    Text(status).font(.footnote).foregroundStyle(failed || !isValid ? Theme.danger : Theme.textSecondary)
                    Spacer()
                    if let current, plain != current.original, writable {
                        Button("Revert") { load(current.original) }.buttonStyle(.link)
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
            if writable {
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .buttonStyle(PillButtonStyle(kind: .primary, height: 36))
                        .fixedSize()
                        .disabled(saving || current.map { plain == $0.original } ?? true || !isValid)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .task { loadAll() }
        .onChange(of: plain) { _, new in
            if let i = entries.firstIndex(where: { $0.id == selected }) {
                entries[i].text = new
            }
            message = nil
            colour()
        }
    }

    // MARK: Editor

    private var editor: some View {
        let lines = max(plain.split(separator: "\n", omittingEmptySubsequences: false).count, 1)
        let lineHeight = Self.font.lineHeight
        return ScrollView {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(1 ... lines, id: \.self) { number in
                        Text("\(number)")
                            .font(Font(Self.font))
                            .foregroundStyle(number == caretLine + 1 ? Theme.textPrimary : Theme.textTertiary)
                            .frame(height: lineHeight)
                    }
                }
                .padding(.top, 8)
                .padding(.horizontal, Theme.s3)
                .accessibilityHidden(true)
                TextEditor(text: $text, selection: $selection)
                    .font(Font(Self.font))
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(true)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .disabled(!writable)
                    .frame(minHeight: CGFloat(lines) * lineHeight + 24)
                    .accessibilityLabel(current?.key ?? "Value")
            }
            .background(alignment: .topLeading) {
                // The line the caret is on, across the whole pane.
                Rectangle().fill(Theme.edge.opacity(0.06))
                    .frame(height: lineHeight)
                    .offset(y: 8 + CGFloat(caretLine) * lineHeight)
                    .animation(Theme.quick, value: caretLine)
            }
        }
        .frame(minHeight: 180, maxHeight: .infinity)
        .glass(radius: Theme.listRadius)
    }

    /// The logical line the caret is on.
    private var caretLine: Int {
        let indices = selection.indices(in: text)
        let index: AttributedString.Index? = switch indices {
        case let .insertionPoint(point): point
        case let .ranges(ranges): ranges.ranges.first?.lowerBound
        }
        guard let index else { return 0 }
        return text.characters[..<index].count { $0 == "\n" }
    }

    private var isValid: Bool {
        guard current?.json == true else { return true }
        return (try? JSONSerialization.jsonObject(with: Data(plain.utf8), options: .fragmentsAllowed)) != nil
    }

    private var status: String {
        if let message {
            return message
        }
        guard let current else { return "" }
        let kind = current.json ? (isValid ? "Valid JSON" : "Not valid JSON") : "Text"
        let edited = plain != current.original ? " · edited" : ""
        return writable ? kind + edited : kind + " · read only while the game runs"
    }

    /// Keys in the secondary colour, values in white, punctuation in tertiary.
    private func colour() {
        let string = plain
        var styled = text
        styled.foregroundColor = Theme.textPrimary
        let ns = string as NSString
        func paint(_ pattern: String, _ color: Color) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            for match in regex.matches(in: string, range: NSRange(location: 0, length: ns.length)) {
                if let range = Range(match.range, in: styled) {
                    styled[range].foregroundColor = color
                }
            }
        }
        paint("[{}\\[\\],:]", Theme.textTertiary)
        paint("\"(?:\\\\.|[^\"\\\\])*\"(?=\\s*:)", Theme.textSecondary)
        if styled != text {
            text = styled
        }
    }

    // MARK: Loading and saving

    private func pick(_ id: String) {
        guard id != selected, let entry = entries.first(where: { $0.id == id }) else { return }
        selected = id
        load(entry.text)
    }

    private func load(_ string: String) {
        text = AttributedString(string)
        selection = AttributedTextSelection()
        colour()
    }

    private func loadAll() {
        entries = paths.compactMap { path in
            let url = location.root.appending(path: path)
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let stem = url.deletingPathExtension().lastPathComponent
            let key = SaveKey.decodeWebStorage(stem) ?? stem
            if let unpacked = LZString.decompressFromBase64(raw), !unpacked.isEmpty, let pretty = Self.pretty(unpacked) {
                return Entry(path: path, key: key, text: pretty, original: pretty, packed: true, json: true)
            }
            if let pretty = Self.pretty(raw) {
                return Entry(path: path, key: key, text: pretty, original: pretty, packed: false, json: true)
            }
            return Entry(path: path, key: key, text: raw, original: raw, packed: false, json: false)
        }
        if let first = entries.first {
            selected = first.id
            load(first.text)
        }
    }

    /// JSON laid out one value per line (keys sorted), or nil when the text is not JSON.
    private static func pretty(_ string: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(string.utf8), options: .fragmentsAllowed),
              let data = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
              )
        else { return nil }
        return String(data: data, encoding: .utf8)
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
        let data = Data((entry.packed ? LZString.compressToBase64(entry.text) : entry.text).utf8)
        let file = location.root.appending(path: entry.path)
        do {
            try await SafePersistTransaction(location: location, identityHash: identityHash)
                .run(targets: [file], reason: .beforeEdit) { staging in
                    try data.write(to: staging.url(for: file), options: .atomic)
                }
            failed = false
            if let i = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[i] = Entry(
                    path: entry.path,
                    key: entry.key,
                    text: entry.text,
                    original: entry.text,
                    packed: entry.packed,
                    json: entry.json
                )
            }
            message = "Saved \(entry.key). The snapshot taken first keeps the old value."
        } catch {
            failed = true
            message = "Nothing was saved: \(error.localizedDescription)"
        }
    }
}
