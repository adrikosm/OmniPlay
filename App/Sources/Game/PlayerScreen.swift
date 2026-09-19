import Diagnostics
import GameCore
import GameStore
import RuntimeCore
import SwiftUI

/// Full-screen game session: the host controller fills the screen, the coordinator owns the runtime, and
/// leaving stops the session before the cover dismisses.
struct PlayerScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let game: GameRecord
    let snapshot: DetectionSnapshot
    @State private var host: RuntimeHostViewController
    @State private var failure: String?
    @State private var notice: String?
    @State private var leaving = false

    init(game: GameRecord, snapshot: DetectionSnapshot) {
        self.game = game
        self.snapshot = snapshot
        let orientation = WebProfile.derive(from: snapshot.report.descriptor).orientation
        _host = State(initialValue: RuntimeHostViewController(sessionID: SessionID(), orientation: orientation))
    }

    var body: some View {
        HostContainer(controller: host)
            .ignoresSafeArea()
            .statusBarHidden()
            .overlay(alignment: .bottom) {
                if let notice {
                    Text(notice).font(.footnote).foregroundStyle(Theme.textPrimary).padding(Theme.s3).glassCard(radius: 12).padding(
                        .bottom,
                        Theme.s8
                    )
                    .transition(.opacity)
                }
            }
            .task { await start() }
            .alert("The game could not start", isPresented: Binding(get: { failure != nil }, set: {
                if !$0 {
                    failure = nil
                }
            })) {
                Button("Back to library") { Task { await leave() } }
            } message: {
                Text(failure ?? "")
            }
            .onChange(of: host.sessionID) { _, _ in }
    }

    private func start() async {
        host.onExitRequested = { Task { await leave() } }
        host.onEvent = { event in
            if case let .log(category, message) = event, category == .javascript, message.hasPrefix("[error]") {
                // errors are already in the session log; nothing to show here yet
                _ = message
            }
        }
        do {
            _ = try await model.play(game, snapshot: snapshot, host: host)
        } catch let error as CoordinatorError {
            failure = Self.describe(error)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func leave() async {
        guard !leaving else { return }
        leaving = true
        await model.stopPlaying()
        dismiss()
    }

    static func describe(_ error: CoordinatorError) -> String {
        switch error {
        case .busy: "Another game is still closing. Try again in a moment."
        case let .preflight(p):
            switch p {
            case .ok: "Ready."
            case .slotBusy: "Another game is running."
            case .slotSpent: "This engine needs OmniPlay to restart before it can run another game."
            case let .notBuilt(r): "The \(DetectionExplainerName.name(r)) runtime is not part of this build."
            case let .noRuntime(reason): reason
            }
        case let .prepareFailed(d): "Preparing the game failed: \(d)"
        case let .startFailed(d): "Starting the game failed: \(d)"
        }
    }
}

/// Bridges the UIKit host controller into SwiftUI without re-creating it on updates.
private struct HostContainer: UIViewControllerRepresentable {
    let controller: RuntimeHostViewController
    func makeUIViewController(context _: Context) -> RuntimeHostViewController { controller }
    func updateUIViewController(_: RuntimeHostViewController, context _: Context) {}
}

import GameDetection

enum DetectionExplainerName {
    static func name(_ r: RuntimeIdentifier) -> String { DetectionExplainer.name(r) }
}
