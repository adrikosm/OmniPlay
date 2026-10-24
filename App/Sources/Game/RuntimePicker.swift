import GameCore
import GameDetection
import GameStore
import OverlayVFS
import PhotosUI
import RuntimeCore
import SaveKit
import SwiftUI

/// Choose a runtime: a small sheet with the plausible runtimes (best match first), a reason for each, and one
/// button that applies the choice. When detection found nothing, every runtime this build has is offered to try.
/// Applying first looks at the game's files again. The choice is stored for this game only.
struct RuntimePicker: View {
    @Environment(AppModel.self) private var model
    let game: GameRecord
    let report: DetectionReport
    let current: RuntimeIdentifier?
    let close: () -> Void
    let choose: (RuntimeIdentifier?) async -> Void
    @State private var picked: RuntimeIdentifier?
    @State private var working = false
    @State private var message: String?
    /// Every runtime this build has, offered when detection named none.
    @State private var others: [RuntimeIdentifier] = []
    @State private var hasPage = true

    var body: some View {
        let candidates = DetectionExplainer.candidates(report)
        let selection = picked ?? current ?? candidates.first?.runtime
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: "Choose a runtime", close: close)
            Text("OmniPlay isn't sure which engine build \(game.title) needs. The best match is first; this applies to this game only.")
                .font(.footnote).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: Theme.s2) {
                ForEach(candidates) { choice in
                    RadioRow(
                        title: DetectionExplainer.name(choice.runtime),
                        subtitle: choice.reason,
                        selected: choice.runtime == selection
                    ) {
                        picked = choice.runtime
                    }
                }
                ForEach(others, id: \.self) { runtime in
                    let blocked = runtime == .web && !hasPage
                    RadioRow(
                        title: DetectionExplainer.name(runtime),
                        subtitle: blocked ? "No web page in this game's files" : "Not detected. You can try it.",
                        selected: runtime == selection
                    ) {
                        picked = runtime
                    }
                    .disabled(blocked)
                    .opacity(blocked ? 0.45 : 1)
                }
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Button {
                Task { await apply(selection) }
            } label: {
                HStack(spacing: Theme.s2) {
                    if working {
                        ProgressView()
                        Text("Checking the game's files…")
                    } else {
                        Text(selection.map { "Use \(DetectionExplainer.name($0))" } ?? "Use this runtime")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.primary)
            .disabled(selection == nil || working)
            Button("Back to automatic choice") { Task { await apply(nil) } }
                .buttonStyle(.link)
                .frame(maxWidth: .infinity)
                .disabled(working)
        }
        .task {
            guard candidates.isEmpty else { return }
            let name = DetectionExplainer.name
            others = await model.registry.bundled().map(\.id).sorted { name($0) < name($1) }
            // SQLite's GLOB `*` crosses folders, so this finds a page at any depth.
            let index = model.paths.game(game.id).appending(path: "index.sqlite")
            hasPage = (try? PathIndex.open(at: index).glob(layer: "original", pattern: "*.html", limit: 1).isEmpty == false) ?? true
        }
    }

    private func apply(_ runtime: RuntimeIdentifier?) async {
        working = true
        message = nil
        // A check that fails has rolled itself back; the choice still applies to the files as they are.
        if case .busy? = try? await model.recheck(game.id) {
            message = "This game is being imported or deleted. Try again in a moment."
            working = false
            return
        }
        await choose(runtime)
    }
}
