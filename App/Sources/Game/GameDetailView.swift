import GameCore
import GameStore
import SwiftUI

/// Header with cover and title, the primary action, and what detection found. Runtimes arrive with later
/// milestones, so Play is disabled with a plain reason rather than a button that fails.
struct GameDetailView: View {
    @Environment(AppModel.self) private var model
    let game: GameRecord
    @State private var detection: DetectionResultRecord?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s6) {
                header
                actions
                summary
            }
            .padding(Theme.s4)
            .padding(.bottom, Theme.s8)
        }
        .inkScreen()
        .navigationTitle(game.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadDetection() }
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
        }
    }

    private var playReason: String {
        switch game.engine.tier {
        case .refused: "\(game.engine.displayName) games need a native Windows runtime and cannot run on iPhone."
        case .core, .breadth, .opportunistic: "The \(game.engine.displayName) runtime is not part of this build yet."
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            Text("What OmniPlay found").font(.headline).foregroundStyle(Theme.textPrimary)
            row("Engine", game.engine.displayName)
            row("Confidence", game.detectionConfidence.formatted(.percent.precision(.fractionLength(0))))
            row("Size on disk", game.installBytes.formatted(.byteCount(style: .file)))
            row("Added", game.importedAt.formatted(date: .abbreviated, time: .shortened))
            if let detection, !detection.evidenceJson.isEmpty {
                Divider().overlay(Theme.hairline)
                ForEach(detection.evidenceJson, id: \.self) { evidence in
                    HStack(alignment: .top) {
                        Text(evidence.check).font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(evidence.outcome).font(.caption).foregroundStyle(Theme.textPrimary).multilineTextAlignment(.trailing)
                    }
                }
            }
        }
        .padding(Theme.s4)
        .glassCard()
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value).foregroundStyle(Theme.textPrimary)
        }
        .font(.subheadline)
    }

    private func loadDetection() async {
        guard let store = model.store else { return }
        let id = game.id
        detection = await Task.detached { try? store.detection.latest(for: id) }.value
    }
}
