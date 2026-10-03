import GameStore
import GameTools
import SwiftUI
import UniformTypeIdentifiers

/// A game's mods: install from Files (a ZIP, a folder, or a single script or plugin), switch each on or off, order
/// them (higher wins where two replace the same file), see those overlaps, and remove them. The game's own files are
/// never changed; everything applies the next time the game starts.
struct ModsView: View {
    @Environment(AppModel.self) private var model
    let game: GameRecord
    let running: Bool
    @State private var mods: [ModRecord] = []
    @State private var conflicts: [ModConflict] = []
    @State private var importing = false
    @State private var busy = false
    @State private var message: String?
    @State private var warnings: [String] = []
    @State private var pendingRemoval: ModRecord?

    var body: some View {
        ScrollView {
            Split(spacing: Theme.s6, leadingWidth: 320) {
                VStack(alignment: .leading, spacing: Theme.s4) {
                    Text(running
                        ? "Changes apply the next time the game starts."
                        : "Mods sit on top of the game; its own files stay as they are. Changes apply the next time it starts.")
                        .font(.subheadline).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { importing = true } label: { Label(busy ? "Installing…" : "Install a mod", systemImage: "plus") }
                        .buttonStyle(.primary)
                        .disabled(busy)
                    if mods.contains(where: \.enabled) {
                        Button {
                            Task {
                                for mod in mods where mod.enabled {
                                    await model.setModEnabled(mod, false)
                                }
                                reload()
                                message = "Every mod is off: the game starts as it shipped."
                            }
                        } label: { Text("Turn all mods off") }
                            .buttonStyle(.secondary)
                    }
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                }
                .rise(0)
            } trailing: {
                VStack(alignment: .leading, spacing: Theme.s6) {
                    GlassSection(
                        "Installed",
                        footer: mods.count > 1 ? "Higher in the list wins where two mods replace the same file." : nil
                    ) {
                        if mods.isEmpty {
                            ListRow(title: "No mods installed", dimmed: true)
                        }
                        ForEach(Array(mods.enumerated()), id: \.element.id) { index, mod in
                            row(mod, first: index == 0, last: index == mods.count - 1)
                        }
                    }
                    if !conflicts.isEmpty {
                        conflictList
                    }
                }
                .rise(1)
            }
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s3)
        }
        .canvas()
        .navigationTitle("Mods")
        .navigationBarTitleDisplayMode(.inline)
        .task { reload() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, .folder, .archive, .data, .javaScript, .plainText]) { result in
            if case let .success(url) = result {
                Task { await install(url) }
            }
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.name ?? "this mod")?",
            isPresented: $pendingRemoval.isPresent(),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let mod = pendingRemoval {
                    Task {
                        await model.uninstallMod(mod)
                        reload()
                    }
                }
            }
        } message: {
            Text(
                """
                It stops loading at the next launch; its files are kept for a week. Saves made with it keep working \
                only if the game does not need it.
                """
            )
        }
    }

    private func row(_ mod: ModRecord, first: Bool, last: Bool) -> some View {
        let kind = ModContentType(rawValue: mod.contentType)?.title ?? mod.contentType
        let overlaps = mod.conflictsJson.isEmpty ? "" : " · \(mod.conflictsJson.count) overlap\(mod.conflictsJson.count == 1 ? "" : "s")"
        return HStack(spacing: Theme.s2) {
            ListRow(title: mod.name, subtitle: "\(kind) · \(mod.filesJson.count) file\(mod.filesJson.count == 1 ? "" : "s")" + overlaps) {
                Toggle(mod.name, isOn: Binding(get: { mod.enabled }, set: { on in
                    Task {
                        await model.setModEnabled(mod, on)
                        reload()
                    }
                }))
                .labelsHidden()
            }
            Menu {
                Button("Move up", systemImage: "arrow.up") { model.moveMod(mod, up: true); reload() }.disabled(first)
                Button("Move down", systemImage: "arrow.down") { model.moveMod(mod, up: false); reload() }.disabled(last)
                Button("Remove", systemImage: "trash", role: .destructive) { pendingRemoval = mod }
            } label: {
                Image(systemName: "ellipsis").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                    .frame(width: 40, height: 44)
            }
            .tint(Theme.textPrimary)
            .padding(.trailing, Theme.s1)
            .accessibilityLabel("More for \(mod.name)")
        }
    }

    private var conflictList: some View {
        GlassSection(
            "Overlaps",
            footer: conflicts.count > 50
                ? "And \(conflicts.count - 50) more."
                : "These files come from more than one mod; the one higher in the list is used."
        ) {
            ForEach(conflicts.prefix(50)) { conflict in
                VStack(alignment: .leading, spacing: 2) {
                    Text(conflict.path).font(Theme.mono).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                    Text("From \(name(conflict.winner)), over \(conflict.losers.map(name).joined(separator: ", "))")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.s4).padding(.vertical, 10)
            }
        }
    }

    private func name(_ id: String) -> String { mods.first { $0.id == id }?.name ?? id }

    private func reload() {
        mods = model.mods(for: game.id)
        conflicts = model.modConflicts(for: game.id)
    }

    private func install(_ url: URL) async {
        busy = true
        defer { busy = false }
        do {
            let (record, validation) = try await model.installMod(from: url, for: game)
            message = "Installed \(record.name) (\(validation.contentType.title))."
            warnings = validation.warnings
        } catch {
            message = "Not installed: \(error.localizedDescription)"
            warnings = []
        }
        reload()
    }
}
