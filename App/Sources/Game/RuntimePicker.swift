import GameCore
import GameDetection
import GameStore
import PhotosUI
import RuntimeCore
import SaveKit
import SwiftUI

/// Choose a runtime: a small sheet with the plausible runtimes (best match first), a reason for each, and one
/// button that applies the choice. The choice is stored for this game only.
struct RuntimePicker: View {
    let game: GameRecord
    let report: DetectionReport
    let current: RuntimeIdentifier?
    let close: () -> Void
    let choose: (RuntimeIdentifier?) async -> Void
    @State private var picked: RuntimeIdentifier?
    @State private var working = false

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
            }
            Button {
                working = true
                Task { await choose(selection) }
            } label: {
                Text(selection.map { "Use \(DetectionExplainer.name($0))" } ?? "Use this runtime").frame(maxWidth: .infinity)
            }
            .buttonStyle(.primary)
            .disabled(selection == nil || working)
            Button("Back to automatic choice") {
                working = true
                Task { await choose(nil) }
            }
            .buttonStyle(.link)
            .frame(maxWidth: .infinity)
            .disabled(working)
        }
    }
}
