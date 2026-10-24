import GameCore
import GameStore
import SaveKit
import SwiftUI
import UIKit

/// One file in a game's `Saves/slots`.
struct SaveSlotFile: Identifiable, Hashable, Sendable {
    let url: URL
    let bytes: Int64
    let modified: Date?

    var id: String { url.lastPathComponent }
    /// RPG Maker MV/MZ saves open in the offline editor; others are edited in the running game.
    var isOfflineEditable: Bool { ["rpgsave", "rmmzsave"].contains(url.pathExtension.lowercased()) }
    /// Web-storage keys (`ls.<base64>`) read as the key the game used.
    var displayName: String { SaveKey.decodeWebStorage(url.deletingPathExtension().lastPathComponent) ?? url.lastPathComponent }

    static func list(in folder: URL) -> [SaveSlotFile] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return items.compactMap { url in
            guard !url.lastPathComponent.hasPrefix("."), SaveSlots.isSlot(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { return nil }
            return SaveSlotFile(url: url, bytes: Int64(values.fileSize ?? 0), modified: values.contentModificationDate)
        }
        .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }
}

/// A slot as the player knows it: the game's own screenshot and name for the save when it keeps them, then when it
/// was saved and its size. A tap opens its details; touch and hold for edit, duplicate and delete.
struct SaveSlotRow: View {
    let slot: SaveSlotFile
    let preview: SavePreview?

    var body: some View {
        HStack(spacing: Theme.s3) {
            SaveThumbnail(data: preview?.thumbnail, width: 64, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(preview?.title ?? slot.displayName).font(.subheadline).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(subtitle).font(.footnote).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: Theme.s2)
            Chevron()
        }
        .padding(.horizontal, Theme.s4)
        .frame(minHeight: 66)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows details")
    }

    private var subtitle: String {
        [
            (preview?.savedAt ?? slot.modified).map(\.dayAndTime),
            preview?.playtime.map { "played \($0)" },
            slot.bytes.formatted(.byteCount(style: .file)),
        ].compactMap(\.self).joined(separator: " · ")
    }
}

/// The game's picture for a save, or a slate placeholder of the same shape.
struct SaveThumbnail: View {
    let data: Data?
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: width * 3, height: height * 3)) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Theme.slateTop, Theme.slateBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .frame(width: width, height: height)
        .clipShape(.rect(cornerRadius: max(6, width / 16), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: max(6, width / 16), style: .continuous).strokeBorder(
            Theme.edge.opacity(0.12),
            lineWidth: 0.5
        ))
        .accessibilityHidden(true)
    }
}

/// What OmniPlay can tell about one save, in a small centred sheet: the preview, its name and where it was made,
/// the file facts and the validator's reading, then what can be done with it.
struct SaveSlotDetails: View {
    let slot: SaveSlotFile
    let preview: SavePreview?
    let family: SaveFamily
    let close: () -> Void
    let onEdit: (() -> Void)?
    let onDuplicate: (() -> Void)?
    let onDelete: (() -> Void)?
    @State private var validation: SaveValidation?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                SaveThumbnail(data: preview?.thumbnail, width: 200, height: 126)
                VStack(alignment: .leading, spacing: Theme.s2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(preview?.title ?? slot.displayName).font(.title2.weight(.bold)).tracking(-0.5)
                            .foregroundStyle(Theme.textPrimary).lineLimit(2)
                        Spacer(minLength: Theme.s2)
                        Button(action: close) { Image(systemName: "xmark").font(.system(size: 13, weight: .bold)) }
                            .buttonStyle(.round(32)).frame(width: 44, height: 44).accessibilityLabel("Close")
                    }
                    if let party = preview?.characters, !party.isEmpty {
                        Text(party.joined(separator: ", ")).font(.subheadline).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                        fact("Saved", (preview?.savedAt ?? slot.modified)?.dayAndTime ?? "—")
                        fact("File", slot.displayName, mono: true)
                        fact("Size", slot.bytes.formatted(.byteCount(style: .file)))
                        if let playtime = preview?.playtime {
                            fact("Played", playtime)
                        }
                        if let validation {
                            fact("Format", validation.format.rawValue)
                            fact(
                                "Fits",
                                validation.matchesFamily ? "This game" : "Another engine's save",
                                failed: !validation.matchesFamily
                            )
                            if let version = validation.versionHint {
                                fact("Engine", version)
                            }
                        }
                    }
                    .padding(.top, Theme.s1)
                }
            }
            if let warnings = validation?.warnings, !warnings.isEmpty {
                Text(warnings.joined(separator: "\n")).font(.footnote).foregroundStyle(Theme.danger)
            }
            HStack(spacing: 10) {
                if let onEdit {
                    Button("Edit", action: onEdit).buttonStyle(.secondary).frame(maxWidth: .infinity)
                }
                if let onDuplicate {
                    Button("Duplicate", action: onDuplicate).buttonStyle(.secondary).frame(maxWidth: .infinity)
                }
                if let onDelete {
                    Button("Delete", role: .destructive, action: onDelete).buttonStyle(.destructive).frame(maxWidth: .infinity)
                }
                ShareLink(item: slot.url) { Text("Export") }.buttonStyle(.primary).frame(maxWidth: .infinity)
            }
        }
        .task {
            let (url, family) = (slot.url, family)
            validation = await Task.detached { SaveValidator.validate(file: url, family: family) }.value
        }
    }

    private func fact(_ label: String, _ value: String, mono: Bool = false, failed: Bool = false) -> some View {
        GridRow {
            Text(label).font(.footnote).foregroundStyle(Theme.textSecondary)
            Text(value).font(mono ? Theme.mono : .footnote).foregroundStyle(failed ? Theme.danger : Theme.textPrimary)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

/// "Saves changed in the Files app", asked before a launch and when Saves opens. Use them imports the changed files
/// through the normal save import, which backs up the current saves first; Ignore puts the folder back to the real
/// saves. `done` runs once either has happened; the close button leaves everything as it is.
struct SavesChangedSheet: View {
    @Environment(AppModel.self) private var model
    let game: GameRecord
    let changes: Int
    let close: () -> Void
    let done: () -> Void
    /// What the import said instead of installing: warnings can be confirmed, refusals only ignored.
    @State private var problem: (title: String, lines: [String], canConfirm: Bool)?
    @State private var busy = false
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            SheetHeader(title: problem?.title ?? "Saves changed in the Files app", close: close)
            if let problem {
                ForEach(problem.lines, id: \.self) { line in
                    Text(line).font(.subheadline).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("\(changes) file\(changes == 1 ? " was" : "s were") added or changed in Titles › Saves › \(folder).")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.s4) { buttons }
                VStack(alignment: .leading, spacing: 10) { buttons }
            }
            .disabled(busy)
            Text(problem?.canConfirm == false
                ? "Ignore puts the folder back to your current saves, which stay as they are."
                : "Your current saves are backed up first. Ignore puts the folder back to them.")
                .font(.footnote).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { appeared = true }
        .sensoryFeedback(.warning, trigger: appeared)
    }

    private var folder: String { model.saveMirror.folder(for: game.id, title: game.title).lastPathComponent }

    @ViewBuilder private var buttons: some View {
        if problem?.canConfirm != false {
            Button(problem == nil ? "Use them" : "Use them anyway") { Task { await use(confirmed: problem != nil) } }
                .buttonStyle(.primary)
            Button("Ignore") { Task { await ignore() } }.buttonStyle(.link)
        } else {
            Button("Ignore") { Task { await ignore() } }.buttonStyle(.primary)
        }
    }

    private func use(confirmed: Bool) async {
        busy = true
        defer { busy = false }
        do {
            switch try await model.useMirrorChanges(for: game, confirmed: confirmed) {
            case .installed: done()
            case let .needsConfirmation(warnings): problem = ("Use these saves anyway?", warnings, true)
            case let .nothingRecognised(reasons): problem = ("These files could not be used", reasons, false)
            }
        } catch {
            problem = ("These files could not be used", ["Nothing was changed: \(error.localizedDescription)"], false)
        }
    }

    private func ignore() async {
        busy = true
        await model.mirrorSaves(game.id, title: game.title, force: true)
        busy = false
        done()
    }
}
