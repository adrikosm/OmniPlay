import GameCore
import GameDetection
import GameStore
import PhotosUI
import RuntimeCore
import SaveKit
import SwiftUI

extension GameDetailView {
    // MARK: Technical details

    var technical: some View {
        Split {
            VStack(alignment: .leading, spacing: Theme.s6) {
                if let snapshot {
                    GlassSection("Detection", footer: DetectionExplainer.summary(snapshot.report)) {
                        ListRow(title: "Confidence") {
                            RowValue(text: snapshot.report.confidence.formatted(.percent.precision(.fractionLength(0))))
                        }
                        ListRow(title: "Runtime") {
                            RowValue(text: snapshot.resolution.selectedRuntime.map(DetectionExplainer.name) ?? "None")
                        }
                        if !snapshot.resolution.requiredPreparation.isEmpty {
                            ListRow(
                                title: "Before first launch",
                                subtitle: snapshot.resolution.requiredPreparation.map(Self.describe).joined(separator: ", ")
                            )
                        }
                        ListRow(title: "Size") { RowValue(text: game.installBytes.formatted(.byteCount(style: .file))) }
                        ListRow(title: "Added") { RowValue(text: game.importedAt.formatted(date: .abbreviated, time: .omitted)) }
                    }
                } else {
                    Text("Loading what OmniPlay found.").font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                runSettings
            }
        } trailing: {
            if let snapshot {
                VStack(alignment: .leading, spacing: Theme.s6) {
                    ForEach(DetectionExplainer.sections(snapshot.report)) { section in
                        GlassSection(section.title) {
                            ForEach(section.lines, id: \.self) { line in
                                Text(line).font(.footnote).foregroundStyle(Theme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, Theme.s4).padding(.vertical, 10)
                            }
                        }
                    }
                }
            }
        }
    }

    /// How the game runs: memory saving for very large web titles, and picking a runtime by hand.
    @ViewBuilder var runSettings: some View {
        let lowMemoryEngine = game.engine == .rpgMakerMZ || game.engine == .rpgMakerMV || game.engine == .html5
        let canChoose = snapshot.map { snap in
            let r = snap.resolution
            return (!r.fallbacks.isEmpty || r.selectedRuntime == nil)
                && (snap.report.outcome.isPlayableClass || snap.report.outcome == .unknownEngine || snap.report.outcome == .unknownVersion)
        } ?? false
        if lowMemoryEngine || canChoose {
            GlassSection("How it runs") {
                if lowMemoryEngine {
                    ListRow(
                        icon: "memorychip",
                        title: "Reduce memory use",
                        subtitle: "Smaller image cache and 1x rendering for very large titles."
                    ) {
                        Toggle("Reduce memory use", isOn: Binding(get: { lowMemory }, set: { on in
                            lowMemory = on
                            model.setLowMemory(on, for: game.id)
                        }))
                        .labelsHidden()
                    }
                }
                if canChoose {
                    Button { withTransaction(\.disablesAnimations, true) { showPicker = true } } label: {
                        ListRow(
                            icon: "cpu",
                            title: snapshot?.resolution.manualOverride == true ? "Change runtime" : "Choose a runtime yourself"
                        ) {
                            Chevron()
                        }
                    }
                    .buttonStyle(.row)
                }
            }
        }
    }

    /// Cover override: the game's own art stays the default; a user's picture is copied and downsampled.
    var coverMenu: some View {
        Menu { coverMenuItems } label: { Label("Change cover", systemImage: "photo.badge.plus") }
            .tint(Theme.textPrimary)
    }

    @ViewBuilder var coverMenuItems: some View {
        Button("Cover from Photos", systemImage: "photo") { showPhotos = true }
        Button("Cover from Files", systemImage: "folder") { showFiles = true }
        if artworkPath != nil {
            Button("Remove cover", systemImage: "trash", role: .destructive) { Task { await setCover(nil) } }
        }
    }

    /// ImageIO reads the picked file in place and decodes only a thumbnail, off the main actor: a large file picked by
    /// mistake is never loaded whole.
    func importCover(from url: URL) async {
        let (id, paths) = (game.id, model.paths)
        let path = await Task.detached { () -> String? in
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            return CoverExtractor.write(source: url, game: id, paths: paths)
        }.value
        if let path {
            await setCover(path)
        }
    }

    func importCover(data: Data) async {
        let (id, paths) = (game.id, model.paths)
        let path = await Task.detached { () -> String? in
            let temp = FileManager.default.temporaryDirectory.appending(path: "cover-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temp) }
            guard (try? data.write(to: temp)) != nil else { return nil }
            return CoverExtractor.write(source: temp, game: id, paths: paths)
        }.value
        if let path {
            await setCover(path)
        }
    }

    func setCover(_ path: String?) async {
        guard let store = model.store, var record = try? store.games.fetch(id: game.id) else { return }
        if path == nil, let old = record.artworkPath {
            try? FileManager.default.removeItem(at: model.paths.url(forStored: old))
        }
        record.artworkPath = path
        try? store.games.update(record)
        withAnimation(Theme.quick) { artworkPath = path }
    }

    var slotSpent: Bool {
        if case .slotSpent = preflight {
            return true
        }
        return false
    }

    var canPlay: Bool { snapshot?.resolution.selectedRuntime != nil && snapshot?.report.outcome.isPlayableClass == true }
    var lastPlayedAt: Date? { facts.lastPlayedAt ?? game.lastPlayedAt }
    var playTitle: String { lastPlayedAt == nil ? "Play" : "Continue" }

    /// A one-game-per-process engine is spent once its game ends: the page offers Save & Relaunch instead of Play.
    func refreshAfterPlay() async {
        await loadFacts()
        if let snapshot {
            preflight = await model.preflight(game, snapshot: snapshot)
        }
    }

    var playReason: String {
        guard let snapshot else { return "Loading what OmniPlay found." }
        let r = snapshot.resolution
        switch snapshot.report.outcome {
        case let .refused(reason): return reason.humanMessage
        case let .unsupported(reason): return reason
            .hasPrefix("no bundled runtime") ? "The \(game.engine.displayName) runtime is not part of this build yet." : reason
        case .unknownEngine: return "OmniPlay could not tell which engine this is. You can pick a runtime to try."
        case .unknownVersion: return "The engine version is unclear. You can pick a runtime to try."
        default:
            if let selected = r.selectedRuntime {
                return "Runs on \(DetectionExplainer.name(selected))."
            }
            return r.reason
        }
    }

    static func describe(_ step: PreparationStep) -> String {
        switch step {
        case let .mediaJobs(n): "convert \(n) video\(n == 1 ? "" : "s")"
        case .buildCaseIndex: "index files"
        case .installHostShims: "install web shims"
        case .writeRuntimeConfig: "write settings"
        case let .rtpCheck(name): "check for \(name)"
        case .soundfontCheck: "check for a soundfont"
        }
    }

    func load() async {
        let id = game.id, paths = model.paths
        async let facts: Void = loadFacts()
        guard var loaded = await Task.detached(operation: { AppModel.snapshot(for: id, paths: paths) }).value else { await facts; return }
        loaded.resolution = await model.freshResolution(for: game, snapshot: loaded)
        snapshot = loaded
        await facts
        #if DEBUG
            if DebugLaunch.playFirstGame, canPlay {
                showPlayer = true
            }
        #endif
    }

    /// The source file, the last session's ending and the newest snapshot. Re-read when a session ends.
    func loadFacts() async {
        guard let store = model.store else { return }
        let (id, paths) = (game.id, model.paths)
        facts = await Task.detached { () -> Facts in
            var out = Facts()
            out.lastPlayedAt = try? store.games.fetch(id: id)?.lastPlayedAt
            // Newest first from the database: an unordered page of rows loses the latest once a game has many sessions.
            out.sourceName = (try? store.imports.recent(game: id, limit: 1))?.first?.sourceName
            if let last = (try? store.sessions.recent(game: id, limit: 1))?.first {
                let crashed = last.teardownVerdict == "endedUnexpectedly" || (last.notes ?? "").hasPrefix("crash")
                out.sessionFailed = crashed
                out.lastSession = last.teardownVerdict == nil ? "Running" : crashed ? "Closed unexpectedly" : "Ended normally"
            }
            out.snapshot = SaveVault.snapshots(location: SaveLocation.forGame(id, paths: paths)).first
                .map { SaveBackupsView.label($0.manifest.provenance.origin) }
            return out
        }.value
    }

    /// "Touch and controller" for engines that read the screen themselves, "Touch pad and controller" for the rest.
    var inputLine: String? {
        guard let descriptor = snapshot?.report.descriptor else { return nil }
        let touchNative = [.renpy, .scummvm, .godot].contains(descriptor.engine) || WebProfile.derive(from: descriptor).touchNative
        return touchNative ? "Touch and controller" : "Touch pad and controller"
    }

    func choose(_ runtime: RuntimeIdentifier?) async {
        if let resolution = await model.chooseRuntime(runtime, for: game.id) {
            snapshot?.resolution = resolution
        }
    }
}
