import Diagnostics
import GameCore
import GameDetection
import GameStore
import InputKit
import RuntimeCore
import SwiftUI

/// Full-screen game session: the host controller fills the screen, the coordinator owns the runtime, and
/// leaving stops the session before the cover dismisses. Touch controls and the pause menu sit above the surface.
struct PlayerScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let game: GameRecord
    let snapshot: DetectionSnapshot
    @State private var host: RuntimeHostViewController
    @State private var failure: String?
    @State private var notice: String?
    @State private var leaving = false
    @State private var menuShown = false
    @State private var controllers = 0
    @State private var capture: ControllerCapture?
    @AppStorage("omniplay.controls.visible") private var controlsVisible = true
    @AppStorage("omniplay.controls.opacity") private var controlsOpacity = 0.55
    @AppStorage("omniplay.controls.hideWithController") private var hideWithController = true

    init(game: GameRecord, snapshot: DetectionSnapshot) {
        self.game = game
        self.snapshot = snapshot
        let orientation = WebProfile.derive(from: snapshot.report.descriptor).orientation
        _host = State(initialValue: RuntimeHostViewController(sessionID: SessionID(), orientation: orientation))
    }

    private var showsControls: Bool { controlsVisible && (controllers == 0 || !hideWithController) && failure == nil }

    var body: some View {
        HostContainer(controller: host)
            .ignoresSafeArea()
            .statusBarHidden()
            .overlay {
                if showsControls {
                    VirtualControlsView(opacity: controlsOpacity) { model.send($0) }
                        .ignoresSafeArea(.keyboard)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if let notice {
                    Text(notice).font(.footnote).foregroundStyle(Theme.textPrimary).padding(Theme.s3).glassCard(radius: 12)
                        .padding(.bottom, Theme.s8)
                        .transition(.opacity)
                }
            }
            .task { await start() }
            .sheet(isPresented: $menuShown, onDismiss: { Task { await model.resume() } }, content: {
                PauseMenu(
                    title: game.title,
                    controlsVisible: $controlsVisible,
                    controlsOpacity: $controlsOpacity,
                    hideWithController: $hideWithController,
                    controllerConnected: controllers > 0,
                    logURL: model.sessionLog,
                    onResume: { menuShown = false },
                    onExit: { Task { await leave() } }
                )
            })
            .alert("The game could not start", isPresented: Binding(get: { failure != nil }, set: {
                if !$0 {
                    failure = nil
                }
            })) {
                Button("Back to library") { Task { await leave() } }
            } message: {
                Text(failure ?? "")
            }
    }

    private func start() async {
        host.onPauseRequested = { Task { await pause() } }
        host.onEvent = { _ in }
        let bus = InputBus()
        bus.onEvent = { model.send($0) }
        let capture = ControllerCapture(bus: bus)
        capture.onControllerCountChanged = { [weak capture] count in
            controllers = count
            OPLog.log(.ui, .info, "controllers connected: \(count) \(capture?.connectedNames ?? [])")
        }
        capture.start()
        OPLog.log(.ui, .info, "touch controls visible=\(controlsVisible) opacity=\(controlsOpacity) controllers=\(controllers)")
        self.capture = capture
        do {
            _ = try await model.play(game, snapshot: snapshot, host: host)
            #if DEBUG
                if DebugLaunch.openPauseMenu {
                    try? await Task.sleep(for: .seconds(2))
                    await pause()
                }
            #endif
        } catch let error as CoordinatorError {
            failure = Self.describe(error)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func pause() async {
        guard !menuShown, !leaving else { return }
        await model.pause()
        menuShown = true
    }

    private func leave() async {
        guard !leaving else { return }
        leaving = true
        menuShown = false
        capture?.stop()
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
            case let .notBuilt(r): "The \(DetectionExplainer.name(r)) runtime is not part of this build."
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
