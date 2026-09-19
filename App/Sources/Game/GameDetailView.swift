import GameCore
import GameDetection
import GameStore
import PhotosUI
import RuntimeCore
import SwiftUI

/// Cover and title, the primary action, what detection found and how the runtime was chosen.
/// Play stays disabled with a plain reason until a runtime is bundled; nothing here decides a runtime itself.
struct GameDetailView: View {
    @Environment(AppModel.self) private var model
    let game: GameRecord
    @State private var snapshot: DetectionSnapshot?
    @State private var showPicker = false
    @State private var showPlayer = false
    @State private var artworkPath: String?
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var photoItem: PhotosPickerItem?
    @State private var lowMemory = false
    @State private var preflight: LaunchPreflight?
    @State private var confirmRelaunch = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s6) {
                header
                actions
                if let snapshot {
                    findings(snapshot)
                }
            }
            .padding(Theme.s4)
            .padding(.bottom, Theme.s8)
        }
        .inkScreen()
        .navigationTitle(game.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            artworkPath = game.artworkPath
            lowMemory = model.isLowMemory(game.id)
            await load()
            if let snapshot {
                preflight = await model.preflight(game, snapshot: snapshot)
            }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image]) { result in
            if case let .success(url) = result {
                Task { await importCover(from: url) }
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await importCover(data: data)
                }
                photoItem = nil
            }
        }
        .sheet(isPresented: $showPicker) {
            if let snapshot {
                RuntimePicker(game: game, report: snapshot.report) { await choose($0) }
            }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            if let snapshot {
                PlayerScreen(game: game, snapshot: snapshot).environment(model)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: Theme.s4) {
            CoverImage(path: artworkPath, engine: game.engine, maxPixels: 800)
                .frame(width: 150, height: 200)
                .clipShape(.rect(cornerRadius: Theme.tileRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.tileRadius).strokeBorder(Theme.hairline, lineWidth: 1))
                .overlay(alignment: .bottomTrailing) { coverMenu.padding(Theme.s2) }
                .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
            VStack(alignment: .leading, spacing: Theme.s2) {
                Text(game.title).font(Theme.title(26)).foregroundStyle(Theme.textPrimary)
                Text(engineLine).font(.subheadline).foregroundStyle(Theme.textSecondary)
                Chip(text: game.compatibilityState.label, tint: game.compatibilityState.tint)
            }
        }
    }

    /// Cover override: the game's own art stays the default; a user's picture is copied and downsampled.
    private var coverMenu: some View {
        Menu {
            Button("Choose from Photos", systemImage: "photo") { showPhotos = true }
            Button("Choose a file", systemImage: "folder") { showFiles = true }
            if artworkPath != nil {
                Button("Remove cover", systemImage: "trash", role: .destructive) { Task { await setCover(nil) } }
            }
        } label: {
            Image(systemName: "pencil")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: .circle)
                .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .accessibilityLabel("Change cover")
    }

    private func importCover(from url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let data = try? Data(contentsOf: url) else { return }
        await importCover(data: data)
    }

    private func importCover(data: Data) async {
        let temp = FileManager.default.temporaryDirectory.appending(path: "cover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard (try? data.write(to: temp)) != nil else { return }
        let (id, paths) = (game.id, model.paths)
        let path = await Task.detached { CoverExtractor.write(source: temp, game: id, paths: paths) }.value
        if let path {
            await setCover(path)
        }
    }

    private func setCover(_ path: String?) async {
        guard let store = model.store, var record = try? store.games.fetch(id: game.id) else { return }
        if path == nil, let old = record.artworkPath {
            try? FileManager.default.removeItem(at: model.paths.url(forStored: old))
        }
        record.artworkPath = path
        try? store.games.update(record)
        withAnimation(Theme.quick) { artworkPath = path }
    }

    private var engineLine: String {
        var line = game.engine.displayName
        if let version = game.version {
            line += " \(version)"
        }
        return line
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            if case .slotSpent = preflight {
                Label("Restart needed. This engine can run one game per app launch.", systemImage: "arrow.counterclockwise.circle")
                    .font(.footnote).foregroundStyle(Theme.lantern)
                    .padding(Theme.s3).frame(maxWidth: .infinity, alignment: .leading).glassCard(radius: 12)
                Button { confirmRelaunch = true } label: {
                    Label("Save & Relaunch", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
                }
                .buttonStyle(LanternButtonStyle())
                .confirmationDialog("Relaunch OmniPlay?", isPresented: $confirmRelaunch, titleVisibility: .visible) {
                    Button("Save & Relaunch") { Task { await model.relaunch(opening: game.id) } }
                } message: {
                    Text("Any running game is stopped and its saves flushed. OmniPlay closes and reopens on this game.")
                }
            } else {
                Button { showPlayer = true } label: { Label(playTitle, systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(LanternButtonStyle())
                    .disabled(!canPlay)
            }
            Text(playReason).font(.footnote).foregroundStyle(Theme.textSecondary)
            if game.engine == .rpgMakerMZ || game.engine == .rpgMakerMV || game.engine == .html5 {
                Toggle(isOn: Binding(get: { lowMemory }, set: { on in
                    lowMemory = on
                    model.setLowMemory(on, for: game.id)
                })) {
                    Label("Reduce memory use", systemImage: "memorychip")
                    Text("Smaller image cache and 1x rendering for very large titles.").font(.caption).foregroundStyle(Theme.textSecondary)
                }
                .tint(Theme.lantern)
                .foregroundStyle(Theme.textPrimary)
                .padding(Theme.s4)
                .glassCard(radius: 14)
                .padding(.top, Theme.s2)
            }
            NavigationLink { SaveBackupsView(game: game) } label: {
                Label("Saves and backups", systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(Theme.textPrimary)
            .frame(minHeight: 44)
            .padding(.horizontal, Theme.s4)
            .glassCard(radius: 14)
            .padding(.top, Theme.s2)
            NavigationLink { DiagnosticsView(game: game, snapshot: snapshot) } label: {
                Label("Diagnostics", systemImage: "stethoscope").frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(Theme.textPrimary)
            .frame(minHeight: 44)
            .padding(.horizontal, Theme.s4)
            .glassCard(radius: 14)
            if let resolution = snapshot?.resolution, !resolution.fallbacks.isEmpty || resolution.selectedRuntime == nil,
               snapshot?.report.outcome.isPlayableClass == true || snapshot?.report.outcome == .unknownEngine || snapshot?.report
               .outcome == .unknownVersion {
                Button(resolution.manualOverride ? "Change runtime" : "Choose a runtime yourself") { showPicker = true }
                    .font(.footnote.weight(.semibold))
            }
        }
    }

    private var canPlay: Bool { snapshot?.resolution.selectedRuntime != nil && snapshot?.report.outcome.isPlayableClass == true }
    private var playTitle: String { game.lastPlayedAt == nil ? "Play" : "Continue" }

    private var playReason: String {
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

    private func findings(_ snapshot: DetectionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            VStack(alignment: .leading, spacing: Theme.s3) {
                Text("What OmniPlay found").font(.headline).foregroundStyle(Theme.textPrimary)
                Text(DetectionExplainer.summary(snapshot.report)).foregroundStyle(Theme.textPrimary)
                row("Confidence", snapshot.report.confidence.formatted(.percent.precision(.fractionLength(0))))
                row("Size on disk", game.installBytes.formatted(.byteCount(style: .file)))
                row("Added", game.importedAt.formatted(date: .abbreviated, time: .shortened))
                if let selected = snapshot.resolution.selectedRuntime {
                    row("Runtime", DetectionExplainer.name(selected))
                }
                if !snapshot.resolution.requiredPreparation.isEmpty {
                    row("Before first launch", snapshot.resolution.requiredPreparation.map(Self.describe).joined(separator: ", "))
                }
            }
            .padding(Theme.s4)
            .glassCard()
            ForEach(DetectionExplainer.sections(snapshot.report)) { section in
                VStack(alignment: .leading, spacing: Theme.s2) {
                    Text(section.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    ForEach(section.lines, id: \.self) { line in
                        Text(line).font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(Theme.s4)
                .glassCard(radius: 14)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value).foregroundStyle(Theme.textPrimary).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
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

    private func load() async {
        let id = game.id, paths = model.paths
        guard var loaded = await Task.detached { AppModel.snapshot(for: id, paths: paths) }.value else { return }
        loaded.resolution = await model.freshResolution(for: game, snapshot: loaded)
        snapshot = loaded
        #if DEBUG
            if DebugLaunch.playFirstGame, canPlay {
                showPlayer = true
            }
        #endif
    }

    private func choose(_ runtime: RuntimeIdentifier?) async {
        if let resolution = await model.chooseRuntime(runtime, for: game.id) {
            snapshot?.resolution = resolution
        }
        showPicker = false
    }
}

/// At most four plausible runtimes with the evidence behind each. The choice is stored for this game only.
private struct RuntimePicker: View {
    let game: GameRecord
    let report: DetectionReport
    let choose: (RuntimeIdentifier?) async -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(DetectionExplainer.candidates(report)) { choice in
                        Button { Task { await choose(choice.runtime) } } label: {
                            VStack(alignment: .leading, spacing: Theme.s1) {
                                Text(DetectionExplainer.name(choice.runtime)).foregroundStyle(Theme.textPrimary)
                                Text(choice.reason).font(.footnote).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                } header: {
                    Text("Runtimes that could fit")
                } footer: {
                    Text("This choice applies to \(game.title) only. OmniPlay keeps choosing automatically for other games.")
                }
                Section { Button("Back to automatic choice") { Task { await choose(nil) } } }
            }
            .listRowBackground(Color.white.opacity(0.05))
            .inkScreen()
            .navigationTitle("Choose a runtime")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
