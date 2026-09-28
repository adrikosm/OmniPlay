import CoreImage
import Diagnostics
import GameCore
import GameDetection
import GameStore
import InputKit
import RuntimeCore
import SwiftUI
import UIKit

/// Full-screen game session: the host controller fills the screen, the coordinator owns the runtime, and
/// leaving stops the session before the cover dismisses. Touch controls and the pause menu sit above the surface.
struct PlayerScreen: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    let game: GameRecord
    let snapshot: DetectionSnapshot
    @State var host: RuntimeHostViewController
    @State var failure: String?
    @State var notice: String?
    @State private var thermalState = ProcessInfo.processInfo.thermalState
    @State var leaving = false
    @State var menuShown = false
    @State var editingControls = false
    @State var overlay: SessionOverlay
    @State var capture: ControllerCapture?
    @State var controls: UIHostingController<OverlayControls>?
    @State var controlsSurface: ControlsPassthroughView?
    /// When the current session started, for telling a failure at boot from one mid-play (RUNTIME-007).
    @State var startedAt = ContinuousClock.now
    @State var pausedFrame: UIImage?
    /// The engine is still starting; shown only if that takes longer than a second.
    @State var starting = false
    @AppStorage("omniplay.controls.opacity") var controlsOpacity = 0.8

    init(game: GameRecord, snapshot: DetectionSnapshot) {
        self.game = game
        self.snapshot = snapshot
        let descriptor = snapshot.report.descriptor
        // Ren'Py and every desktop RPG Maker (2000/2003, XP/VX/VX Ace) draw for a landscape screen; web games say so in
        // their profile. Left to follow the device, an RGSS engine's window could turn portrait under a landscape host
        // and draw its picture off-screen (The Seventh Warrior showed only black).
        let web = WebProfile.derive(from: descriptor)
        let landscape: Set<EngineFamily> = [.renpy, .rpgMaker2000, .rpgMaker2003, .rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce]
        // ScummVM: graphical adventures are landscape; interactive fiction (Glk) is text with a keyboard, which
        // ScummVM itself keeps up in portrait.
        let scummLandscape = descriptor.engine == .scummvm && descriptor.profile.overrides["scummvm.engineid"] != "glk"
        let orientation: OrientationPreference = landscape.contains(descriptor.engine) || scummLandscape ? .landscape : web.orientation
        _host = State(initialValue: RuntimeHostViewController(sessionID: SessionID(), orientation: orientation))
        let overlay = SessionOverlay()
        // Ren'Py and Tyrano take taps and gestures themselves; a gamepad overlay would only sit on the text.
        overlay.touchNative = descriptor.engine == .renpy || descriptor.engine == .scummvm || descriptor.engine == .godot || web.touchNative
        // Godot reads touches itself, but keyboard-only games (Pong) need keys: the pad is there, off until asked for.
        overlay.padOptional = descriptor.engine == .godot
        _overlay = State(initialValue: overlay)
    }

    var body: some View {
        HostContainer(controller: host)
            .ignoresSafeArea()
            .statusBarHidden()
            // A thumb sliding off the pad must stay in the game: edge swipes need a second, deliberate swipe.
            .defersSystemGestures(on: .all)
            .persistentSystemOverlays(.hidden)
            .overlay {
                if let status = model.preparingMedia {
                    VStack(spacing: Theme.s3) {
                        ProgressView(value: status.fraction >= 0 ? status.fraction : nil)
                            .tint(Theme.textPrimary)
                            .frame(width: 220)
                        Text(status.line).font(.footnote).foregroundStyle(Theme.textPrimary).multilineTextAlignment(.center)
                        Text("Converting the game's media for this engine. This happens once.")
                            .font(.caption).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                    }
                    .padding(Theme.s4)
                    .frame(maxWidth: 360)
                    .glass(radius: Theme.listRadius, heavy: true)
                    .accessibilityElement(children: .combine)
                    .transition(.opacity)
                } else if starting {
                    HStack(spacing: Theme.s3) {
                        ProgressView().tint(Theme.textPrimary)
                        Text("Starting \(game.title)…").font(.footnote).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    }
                    .padding(.horizontal, Theme.s4).padding(.vertical, 12)
                    .glass(Capsule(), heavy: true)
                    .accessibilityElement(children: .combine)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if let notice = notice ?? thermalNotice {
                    Text(notice).font(.footnote).foregroundStyle(Theme.textPrimary).padding(.horizontal, Theme.s4).padding(.vertical, 10)
                        .glass(Capsule(), heavy: true)
                        .padding(.bottom, Theme.s8)
                        .transition(.opacity)
                }
            }
            .task { await start() }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
                .receive(on: RunLoop.main)) { _ in
                    thermalState = ProcessInfo.processInfo.thermalState
            }
            .onChange(of: scenePhase) { _, phase in
                overlay.sceneActive = phase == .active
            }
            .onChange(of: model.runtimeNotice) { _, line in
                guard let line, !leaving else { return }
                model.runtimeNotice = nil
                withAnimation(reduceMotion ? nil : Theme.quick) { notice = line }
                Task {
                    try? await Task.sleep(for: .seconds(8))
                    withAnimation(reduceMotion ? nil : Theme.quick) { notice = nil }
                }
            }
            // A save the game made could not be written: said at once, not only when leaving (FIX-F008).
            .onChange(of: model.saveWarning != nil) { _, failed in
                guard failed, !leaving else { return }
                withAnimation(reduceMotion ? nil : Theme.quick) { notice = "A save could not be written. Try saving again." }
                Task {
                    try? await Task.sleep(for: .seconds(8))
                    withAnimation(reduceMotion ? nil : Theme.quick) { notice = nil }
                }
            }
            .overlay {
                if editingControls {
                    ControlsEditorView(
                        layouts: overlay.layouts,
                        builtIn: builtInControls,
                        padVisible: Binding(get: { overlay.padVisible }, set: { overlay.padVisible = $0 })
                    ) { edited in
                        model.setControlsLayouts(edited, for: game.id)
                        overlay.layouts = edited
                        finishEditing()
                    } onCancel: {
                        finishEditing()
                    }
                }
            }
            .fullScreenCover(isPresented: $menuShown, onDismiss: {
                // The editor keeps the game paused; it resumes when the editor closes.
                if !editingControls, !leaving {
                    Task { await resume() }
                }
            }, content: {
                PauseMenu(
                    title: game.title,
                    backdrop: pausedFrame,
                    played: Self.played(since: startedAt),
                    hasTouchControls: overlay.hasPad,
                    controlsVisible: Binding(get: { overlay.padVisible }, set: { overlay.padVisible = $0 }),
                    controlsOpacity: $controlsOpacity,
                    controllerConnected: overlay.controllers > 0,
                    logURL: model.sessionLog,
                    fastForward: overlay.speed == nil ? nil : overlay.fastForward,
                    speed: overlay.speed ?? .multipliers,
                    onFastForward: { multiplier in
                        overlay.fastForward = multiplier
                        Task { await model.setFastForward(multiplier) }
                    },
                    engineMenu: overlay.engineMenu,
                    onEngineMenu: {
                        closeMenu() // dismissing resumes; the engine opens its menu once running again
                        Task {
                            try? await Task.sleep(for: .milliseconds(600))
                            await model.openEngineMenu()
                        }
                    },
                    gameTools: GameToolsView(game: game, snapshot: snapshot),
                    onEditControls: {
                        editingControls = true
                        overlay.editing = true
                        closeMenu()
                    },
                    onScreenshot: { await screenshot() },
                    onResume: { closeMenu() },
                    onExit: { Task { await leave() } }
                )
            })
            .onChange(of: model.runtimeFailure) { _, message in
                guard !leaving, let message else { return }
                model.runtimeFailure = nil
                let category: FailureCategory = ContinuousClock.now - startedAt <= FallbackPolicy.bootWindow ? .crashAtBoot : .crashInPlay
                fail(message, category: category)
            }
            .alert(leaving ? "Save could not be confirmed" : "Game problem", isPresented: Binding(get: { failure != nil }, set: {
                if !$0 {
                    failure = nil
                }
            })) {
                Button("Back to library") {
                    if leaving {
                        dismiss()
                    } else {
                        Task { await leave() }
                    }
                }
            } message: {
                Text(failure ?? "")
            }
    }

    private var thermalNotice: String? {
        switch thermalState {
        case .serious, .critical: "Your iPhone is warm. Save your progress and pause to let it cool."
        default: nil
        }
    }
}

/// Bridges the UIKit host controller into SwiftUI without re-creating it on updates.
private struct HostContainer: UIViewControllerRepresentable {
    let controller: RuntimeHostViewController
    func makeUIViewController(context _: Context) -> RuntimeHostViewController { controller }
    func updateUIViewController(_: RuntimeHostViewController, context _: Context) {}
}
