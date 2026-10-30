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
    /// The starting note and the passing notices at the bottom, hosted in the runtime host's overlay.
    @State var notes = PlayerNotes()
    @State var notesHost: UIHostingController<PlayerNotesView>?
    @State var introReached = false
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
        // Godot reads touches itself, but keyboard-only games (Pong, platformers) need keys: the pad is there to hide.
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
                }
            }
            .task { await start() }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
                .receive(on: RunLoop.main)) { _ in
                    notes.thermal = ProcessInfo.processInfo.thermalState
            }
            // The media overlay says what is happening meanwhile; the wait for the engine is counted from its end.
            .onChange(of: model.preparingMedia == nil) { _, done in
                notes.preparingMedia = !done
                if done {
                    notes.since = .now
                }
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
                    gameID: game.id,
                    onCapture: { await capture() },
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
}

extension PlayerScreen {
    /// A watched native engine drew for the first time: the starting note goes.
    func firstPicture() {
        OPLog.log(.ui, .info, "launch timing: first frame after \(Self.ms(since: startedAt)) ms")
        notes.settled = true
    }

    /// The notes ride in the overlay like the controls, above them and below the host's pause button; only the leave
    /// button takes touches.
    func installNotes() {
        let surface = ControlsPassthroughView()
        let controller = UIHostingController(rootView: PlayerNotesView(notes: notes, title: game.title) { [weak surface] region in
            surface?.regions = region.map { [$0] } ?? []
        })
        hostInOverlay(controller, surface: surface, at: 1)
        notesHost = controller
    }

    /// Puts a hosted SwiftUI layer into the runtime host's overlay, at `index` among its subviews, filling it.
    func hostInOverlay(_ controller: UIViewController, surface: ControlsPassthroughView, at index: Int) {
        surface.backgroundColor = .clear
        surface.translatesAutoresizingMaskIntoConstraints = false
        controller.view.backgroundColor = .clear
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        host.addChild(controller)
        host.overlayView.insertSubview(surface, at: index)
        surface.addSubview(controller.view)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: host.overlayView.topAnchor),
            surface.bottomAnchor.constraint(equalTo: host.overlayView.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: host.overlayView.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: host.overlayView.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: surface.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
        ])
        controller.didMove(toParent: host)
    }
}

/// What the bottom of the game says: the starting note until the game's first picture, then any passing notice.
@Observable @MainActor
final class PlayerNotes {
    /// The launch has taken over a second; the note is up until `settled`.
    var shown = false
    /// The first picture is on screen (and a web game has gone quiet), or the launch failed.
    var settled = false
    /// A web game's files loaded so far and the last error its page reported. A 4 GB game shows it is still loading.
    var loaded: (files: Int, bytes: Int64)?
    var pageError: String?
    /// What the engine does before its first picture, said once the screen has stayed black a while.
    var stage: String?
    /// When the wait for the engine began.
    var since = Date.now
    var preparingMedia = false
    var notice: String?
    var thermal = ProcessInfo.processInfo.thermalState
    var onLeave: @MainActor () -> Void = {}

    var starting: Bool { (shown || loaded != nil) && !settled && !preparingMedia }

    /// A new launch on `runtime`: the note comes back after a second, counting from now.
    func restart(runtime: RuntimeIdentifier?, firstStart: Bool) {
        (shown, settled, loaded, pageError, since) = (false, false, nil, nil, .now)
        stage = Self.stage(of: runtime, firstStart: firstStart)
    }

    /// What each engine does before its first picture, as its adapter does it; nil where there is nothing to add.
    static func stage(of runtime: RuntimeIdentifier?, firstStart: Bool) -> String? {
        switch runtime {
        case .renpy:
            firstStart ? "Ren'Py is loading the game's scripts. The first start also builds its caches, so it takes longer."
                : "Ren'Py is loading the game's scripts."
        case .godot(bucket: .v44), .godot(bucket: .v47):
            firstStart ? "Godot is loading the game. The first start also compiles its shaders, so it takes longer."
                : "Godot is loading the game."
        case .godot: "Godot is loading the game."
        case .rgss: "Starting the RPG Maker engine, then the game's scripts."
        case .easyrpg: "EasyRPG is reading the game's data."
        case .scummvm: "ScummVM is identifying the game and starting its engine."
        case .web: "The game's page is loading."
        default: nil
        }
    }

    var bottomNotice: String? {
        if let notice {
            return notice
        }
        return switch thermal {
        case .serious, .critical: "Your iPhone is warm. Save your progress and pause to let it cool."
        default: nil
        }
    }
}

/// The starting note and the notice capsule, stacked at the bottom: the game's own picture keeps the middle. Hosted in
/// the runtime host's overlay because a native engine's window draws above this screen.
struct PlayerNotesView: View {
    let notes: PlayerNotes
    let title: String
    /// The leave button's frame, so only it takes touches from the game.
    let onHitRegion: (CGRect?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Black this long and the note says what the engine is doing.
    static let explainAfter = 5.0

    var body: some View {
        VStack(spacing: Theme.s2) {
            if notes.starting {
                TimelineView(.periodic(from: notes.since, by: 1)) { context in
                    startingNote(waited: context.date.timeIntervalSince(notes.since))
                }
                .transition(.opacity)
            }
            if let notice = notes.bottomNotice {
                Text(notice).font(.footnote).foregroundStyle(Theme.textPrimary).padding(.horizontal, Theme.s4).padding(.vertical, 10)
                    .glass(Capsule(), heavy: true)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, Theme.s8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(reduceMotion ? nil : Theme.quick, value: notes.starting)
        .animation(reduceMotion ? nil : Theme.quick, value: notes.bottomNotice)
    }

    private func startingNote(waited: Double) -> some View {
        // As long as the native watchdog gives an engine for its first frame: past it the game may be stuck.
        let long = waited >= NativeWatchdog.firstFrameLimit
        let time = Duration.seconds(Int(waited)).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
        return VStack(alignment: .leading, spacing: Theme.s1) {
            HStack(spacing: Theme.s3) {
                ProgressView().tint(Theme.textPrimary)
                Text(notes.loaded == nil ? "Starting \(title)…" : "Loading game files…")
                    .font(.footnote).foregroundStyle(Theme.textPrimary).lineLimit(1)
            }
            if let loaded = notes.loaded {
                Text("\(loaded.files) files · \(loaded.bytes.formatted(.byteCount(style: .file)))")
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
            }
            if long {
                Text("Still working after \(time). Leave the game if the screen stays black.")
                    .font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
            } else if waited >= Self.explainAfter {
                Text([notes.stage, "Waiting \(time)."].compactMap(\.self).joined(separator: " "))
                    .font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(3)
            }
            if let pageError = notes.pageError {
                Text(pageError).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
            }
            if long {
                Button("Leave game") { notes.onLeave() }
                    .buttonStyle(PillButtonStyle(kind: .secondary, height: 32))
                    .frame(minHeight: 44)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onHitRegion($0) }
                    .onDisappear { onHitRegion(nil) }
            }
        }
        .padding(.horizontal, Theme.s4).padding(.vertical, 12)
        .frame(maxWidth: 360, alignment: .leading)
        .glass(radius: Theme.listRadius, heavy: true)
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if long {
                Button("Leave game") { notes.onLeave() }
            }
        }
    }
}

/// Bridges the UIKit host controller into SwiftUI without re-creating it on updates.
private struct HostContainer: UIViewControllerRepresentable {
    let controller: RuntimeHostViewController
    func makeUIViewController(context _: Context) -> RuntimeHostViewController { controller }
    func updateUIViewController(_: RuntimeHostViewController, context _: Context) {}
}
