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
    /// The engine stopped responding for `NativeWatchdog.hangLimit`: its failure is a hang, never a boot crash.
    @State var hung = false
    /// A boot failure is being handled; the engine's repeated reports of it are dropped.
    @State var failing = false
    @State var pausedFrame: UIImage?
    /// The engine is still starting; shown only if that takes longer than a second.
    @State var starting = false
    /// A web game's files loaded so far and the last error its page reported, until the launch settles: the first
    /// picture, then two seconds with no file asked for. A 4 GB game shows it is still loading, not a black screen.
    @State var loaded: (files: Int, bytes: Int64)?
    @State var pageError: String?
    @State var introReached = false
    @State var launchSettled = false
    @State var settleTask: Task<Void, Never>?
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
                        Button("Play anyway") { model.skipMediaPreparation() }
                            .font(.footnote.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                            .frame(minHeight: 44)
                            .accessibilityHint("Starts now; videos that are not converted yet may not play.")
                    }
                    .padding(Theme.s4)
                    .frame(maxWidth: 360)
                    .glass(radius: Theme.listRadius, heavy: true)
                    .accessibilityElement(children: .combine)
                    .transition(.opacity)
                } else if starting || (!launchSettled && loaded != nil) {
                    VStack(alignment: .leading, spacing: Theme.s1) {
                        HStack(spacing: Theme.s3) {
                            ProgressView().tint(Theme.textPrimary)
                            Text(loaded == nil ? "Starting \(game.title)…" : "Loading game files…")
                                .font(.footnote).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        }
                        if let loaded {
                            Text("\(loaded.files) files · \(loaded.bytes.formatted(.byteCount(style: .file)))")
                                .font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                        }
                        if let pageError {
                            Text(pageError).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
                        }
                    }
                    .padding(.horizontal, Theme.s4).padding(.vertical, 12)
                    .frame(maxWidth: 360, alignment: .leading)
                    .glass(radius: Theme.listRadius, heavy: true)
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
            // The eye over the game puts the host's pause button away with the rest.
            .onChange(of: overlay.chromeHidden) { _, hidden in
                host.pauseButtonHidden = hidden
            }
            .onChange(of: model.runtimeNotice) { _, line in
                guard let line, !leaving else { return }
                model.runtimeNotice = nil
                flash(line, seconds: 8)
            }
            // A save the game made could not be written: said at once, not only when leaving (FIX-F008).
            .onChange(of: model.saveWarning != nil) { _, failed in
                guard failed, !leaving else { return }
                flash("A save could not be written. Try saving again.", seconds: 8)
            }
            .overlay {
                if editingControls {
                    ControlsEditorView(
                        layouts: overlay.layouts,
                        builtIn: builtInControls,
                        padVisible: $overlay.padVisible,
                        onDone: { edited in
                            model.setControlsLayouts(edited, for: game.id)
                            overlay.layouts = edited
                            finishEditing()
                        },
                        onCancel: { finishEditing() },
                        onShare: { model.setSharedControlsLayouts($0, family: padFamily) }
                    )
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
                    controlsVisible: $overlay.padVisible,
                    controlsOpacity: Binding(get: { overlay.layouts?.opacity ?? controlsOpacity }, set: { value in
                        // A layout with its own opacity keeps it; the slider changes that one, else the app's.
                        if overlay.layouts?.opacity != nil {
                            overlay.layouts?.opacity = value
                            model.setControlsLayouts(overlay.layouts, for: game.id)
                        } else {
                            controlsOpacity = value
                        }
                    }),
                    controllerConnected: overlay.controllers > 0,
                    logURL: model.sessionLog,
                    fastForward: overlay.speed == nil ? nil : overlay.fastForward,
                    speed: overlay.speed ?? .multipliers,
                    onFastForward: { multiplier in
                        overlay.fastForward = multiplier
                        Task { await model.coordinator?.setFastForward(multiplier) }
                    },
                    engineMenu: overlay.engineMenu,
                    onEngineMenu: {
                        closeMenu() // dismissing resumes; the engine opens its menu once running again
                        Task {
                            try? await Task.sleep(for: .milliseconds(600))
                            await model.coordinator?.openEngineMenu()
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
                fail(message, category: crashCategory)
            }
            .alert(leaving ? "Save could not be confirmed" : "Game problem", isPresented: $failure.isPresent()) {
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
