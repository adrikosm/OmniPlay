import GameCore
import GameDetection
import GameStore
import RuntimeCore
import SwiftUI

/// Cover and title, the primary action, what detection found and how the runtime was chosen.
/// Play stays disabled with a plain reason until a runtime is bundled; nothing here decides a runtime itself.
struct GameDetailView: View {
    @Environment(AppModel.self) private var model
    let game: GameRecord
    @State private var snapshot: DetectionSnapshot?
    @State private var showPicker = false

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
        .task { await load() }
        .sheet(isPresented: $showPicker) {
            if let snapshot {
                RuntimePicker(game: game, report: snapshot.report) { await choose($0) }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: Theme.s4) {
            CoverImage(path: game.artworkPath, engine: game.engine, maxPixels: 800)
                .frame(width: 150, height: 200)
                .clipShape(.rect(cornerRadius: Theme.tileRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.tileRadius).strokeBorder(Theme.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
            VStack(alignment: .leading, spacing: Theme.s2) {
                Text(game.title).font(Theme.title(26)).foregroundStyle(Theme.textPrimary)
                Text(engineLine).font(.subheadline).foregroundStyle(Theme.textSecondary)
                Chip(text: game.compatibilityState.label, tint: game.compatibilityState.tint)
            }
        }
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
            Button {} label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity) }
                .buttonStyle(LanternButtonStyle())
                .disabled(true)
            Text(playReason).font(.footnote).foregroundStyle(Theme.textSecondary)
            if let resolution = snapshot?.resolution, !resolution.fallbacks.isEmpty || resolution.selectedRuntime == nil,
               snapshot?.report.outcome.isPlayableClass == true || snapshot?.report.outcome == .unknownEngine || snapshot?.report
               .outcome == .unknownVersion {
                Button(resolution.manualOverride ? "Change runtime" : "Choose a runtime yourself") { showPicker = true }
                    .font(.footnote.weight(.semibold))
            }
        }
    }

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
                return "Runs on \(DetectionExplainer.name(selected)). Play arrives with that runtime."
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
        snapshot = await Task.detached { AppModel.snapshot(for: id, paths: paths) }.value
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
