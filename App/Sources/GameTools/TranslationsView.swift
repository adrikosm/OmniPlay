import GameStore
import GameTools
import SwiftUI
import Translation
import UniformTypeIdentifiers

/// A game's translation packs: install (a Ren'Py `tl/` folder, an MTool text dictionary, translated game files or
/// images), grouped by language with one active per language, overlaps with mods, remove, and "Play original" to
/// turn every pack off. The game's own files are never changed; changes apply the next time it starts.
struct TranslationsView: View {
    @Environment(AppModel.self) private var model
    let game: GameRecord
    /// The game's engine can hand its missed lines to live translation.
    var liveTranslation = false
    @State private var liveSource = ""
    @State private var liveStatus: String?
    @State private var prepare: TranslationSession.Configuration?
    @State private var packs: [TranslationPackRecord] = []
    @State private var conflicts: [ModConflict] = []
    @State private var importing = false
    @State private var busy = false
    @State private var message: String?
    @State private var pendingRemoval: TranslationPackRecord?

    private var languages: [String] { Array(Set(packs.map(\.language))).sorted() }

    var body: some View {
        ScrollView {
            Split(spacing: Theme.s6, leadingWidth: 320) {
                VStack(alignment: .leading, spacing: Theme.s4) {
                    Text(
                        "Packs sit on top of the game and never change its files. One pack per language is in use; "
                            + "changes apply the next time the game starts."
                    )
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Button { importing = true } label: { Label(busy ? "Installing…" : "Install a translation", systemImage: "plus") }
                        .buttonStyle(.primary)
                        .disabled(busy)
                    if packs.contains(where: \.enabled) {
                        Button {
                            for pack in packs where pack.enabled {
                                model.setTranslationEnabled(pack, false)
                            }
                            reload()
                            message = "Every translation is off: the game starts in its own language."
                        } label: { Text("Play original") }
                            .buttonStyle(.secondary)
                    }
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                }
                .rise(0)
            } trailing: {
                VStack(alignment: .leading, spacing: Theme.s6) {
                    if packs.isEmpty {
                        GlassSection("Installed") { ListRow(title: "No translations installed", dimmed: true) }
                    }
                    ForEach(languages, id: \.self) { language in
                        GlassSection(language.isEmpty ? "Packs" : Locale.current
                            .localizedString(forIdentifier: language) ?? language.capitalized) {
                                ForEach(packs.filter { $0.language == language }) { row($0) }
                            }
                    }
                    // The simulator has no Translation service; iOS says so in a sheet, so the switch is not offered.
                    #if !targetEnvironment(simulator)
                        if liveTranslation {
                            liveSection
                        }
                    #endif
                    if !conflicts.isEmpty {
                        GlassSection("Overlaps with mods", footer: "A mod replaces these files too; the mod's version is used.") {
                            ForEach(conflicts.prefix(30)) { conflict in
                                Text(conflict.path).font(Theme.mono).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, Theme.s4).padding(.vertical, 10)
                            }
                        }
                    }
                }
                .rise(1)
            }
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s3)
        }
        .canvas()
        .navigationTitle("Translations")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            reload()
            liveSource = model.profileValue("liveTranslation", for: game.id) ?? ""
            await checkLive()
        }
        .translationTask(prepare) { session in
            // The framework's session is not Sendable; this closure is its only user.
            nonisolated(unsafe) let session = session
            do {
                try await session.prepareTranslation()
                await checkLive()
            } catch {
                liveStatus = "The language could not be downloaded: \(error.localizedDescription)"
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, .folder, .archive, .json]) { result in
            if case let .success(url) = result {
                Task { await install(url) }
            }
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.name ?? "this pack")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: {
                if !$0 {
                    pendingRemoval = nil
                }
            }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let pack = pendingRemoval {
                    model.removeTranslation(pack)
                    reload()
                }
            }
        }
    }

    private func row(_ pack: TranslationPackRecord) -> some View {
        ListRow(title: pack.name, subtitle: TranslationFormat(rawValue: pack.format)?.title ?? pack.format) {
            Toggle(pack.name, isOn: Binding(get: { pack.enabled }, set: { on in
                model.setTranslationEnabled(pack, on)
                reload()
            }))
            .labelsHidden()
        }
        .contextMenu {
            Button("Remove", systemImage: "trash", role: .destructive) { pendingRemoval = pack }
        }
        .accessibilityAction(named: "Remove") { pendingRemoval = pack }
    }

    private func reload() {
        packs = model.translationPacks(for: game.id)
        conflicts = model.translationConflicts(for: game.id)
    }

    private func install(_ url: URL) async {
        busy = true
        defer { busy = false }
        do {
            let (pack, detection) = try await model.installTranslation(from: url, for: game)
            message = "Installed \(pack.name): \(detection.format.title)" +
                (detection.entries > 0 ? ", \(detection.entries) entries." : ".")
        } catch {
            message = "Not installed: \(error.localizedDescription)"
        }
        reload()
    }

    // MARK: Live translation

    private static let liveLanguages = ["ja", "zh-Hans", "zh-Hant", "ko"]

    private var target: String {
        "English"
    }

    private var liveSection: some View {
        GlassSection(
            "Live translation",
            footer: "Lines no pack covers are translated into \(target) on this iPhone as they appear. Nothing leaves the device."
        ) {
            ListRow(title: "Game's language", subtitle: liveStatus) {
                Picker("Game's language", selection: $liveSource) {
                    Text("Off").tag("")
                    ForEach(Self.liveLanguages, id: \.self) { code in
                        Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(Theme.textPrimary)
            }
        }
        .onChange(of: liveSource) { _, source in
            model.setProfileValue("liveTranslation", source, for: game.id)
            Task {
                await checkLive()
                // Asks iOS for the language, which shows its own download prompt when the pack is missing.
                if !source.isEmpty, liveStatus != nil {
                    prepare = .init(source: .init(identifier: source), target: LiveTranslator.english)
                }
            }
        }
    }

    private func checkLive() async {
        guard !liveSource.isEmpty else { liveStatus = nil; return }
        switch await LiveTranslator.status(from: .init(identifier: liveSource)) {
        case .installed: liveStatus = "Ready. Applies the next time the game starts."
        case .supported: liveStatus = "iOS will download this language first."
        case .unsupported: liveStatus = "This language cannot be translated into \(target) on this iPhone."
        @unknown default: liveStatus = nil
        }
    }
}
