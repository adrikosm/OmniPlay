import CoreImage
import Diagnostics
import GameCore
import GameDetection
import GameStore
import InputKit
import RuntimeCore
import SwiftUI
import UIKit

extension PlayerScreen {
    /// The game's picture while paused: a native engine's frozen frame, the web view's own snapshot, or failing
    /// both the host view as drawn.
    func screenshot() async -> String {
        var image = host.frozenFrameView.isHidden ? nil : host.frozenFrameView.image?.cgImage
        if image == nil {
            image = await model.captureScreen()
        }
        if image == nil, let view = host.view {
            let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
            image = renderer.image { _ in _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: false) }.cgImage
        }
        guard let image else { return "This game's picture could not be captured." }
        let result = await Screenshot.save(image)
        OPLog.log(.ui, .info, "screenshot \(image.width)x\(image.height): \(result)")
        return result
    }

    /// This engine's own pad: the RPG Maker keys for RPG Maker (XP confirming with Enter), the general keys otherwise.
    var builtInControls: ControlsLayoutSet {
        let engine = snapshot.report.descriptor.engine
        let rpgMaker: Set<EngineFamily> = [.rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce, .rpgMakerMV, .rpgMakerMZ, .rpgMaker2000, .rpgMaker2003]
        return .defaults(rpgMaker: rpgMaker.contains(engine), xp: engine == .rpgMakerXP)
    }

    /// The controller icon: hold the game still and open the editor over it; Done or Cancel resumes.
    func editControls() async {
        guard !overlay.paused, !leaving else { return }
        overlay.paused = true
        await model.pause()
        overlay.editing = true
        withAnimation(Theme.motion(Theme.sheet, reduce: reduceMotion)) { editingControls = true }
    }

    func closeMenu() {
        withTransaction(\.disablesAnimations, true) { menuShown = false }
    }

    func finishEditing() {
        editingControls = false
        overlay.editing = false
        Task { await resume() }
    }

    func start() async {
        // Only the drawn controls accept touches; the rest of the hosted layer passes through to the game.
        startedAt = .now
        model.runtimeFailure = nil
        overlay.layouts = model.controlsLayouts(for: game.id) ?? builtInControls
        overlay.padKey = "omniplay.controls.visible.\(game.id)"
        if MouseMode(profile: model.profileValue("mouseMode", for: game.id)) == .touchpad {
            overlay.touchpadSpeed = model.profileValue("mouseSpeed", for: game.id).flatMap(Double.init) ?? 1
        }
        if overlay.hasPad, controls == nil {
            installControls()
        }
        host.onPauseRequested = { Task { await pause() } }
        host.onEvent = { event in handle(event) }
        if capture == nil {
            startCapture()
        }
        await launch()
    }

    /// Engine events that concern the screen: hints to remember, the engine ending, launch timing.
    func handle(_ event: RuntimeEvent) {
        switch event {
        case let .profileHint(key, value):
            model.remember(hint: key, value: value, for: game.id)
        case let .ended(status):
            let category: FailureCategory = ContinuousClock.now - startedAt <= FallbackPolicy.bootWindow ? .crashAtBoot : .crashInPlay
            // An engine that reported an error before ending says why; a clean end with nothing said is the game's Quit.
            if let message = model.runtimeFailure {
                model.runtimeFailure = nil
                fail(message, category: category)
            } else if status == 0 {
                Task { await leave() }
            } else {
                fail("The game stopped with an error (status \(status)). The session log has the details.", category: category)
            }
        case let .gradeReached(grade):
            // UX-PERF-001: Play to the engine's first picture (the web runtime: RPG Maker's scene loop running).
            OPLog.log(.ui, .info, "launch timing: \(grade) after \(Self.ms(since: startedAt)) ms")
        default:
            break
        }
    }

    /// Controllers: buttons go through the input bus; Options opens OmniPlay's menu.
    func startCapture() {
        let bus = InputBus()
        bus.onEvent = { model.send($0) }
        let capture = ControllerCapture(bus: bus, mapping: model.controllerMapping(for: game.id))
        // Options opens OmniPlay's menu; the mapping screen, while open, takes buttons for itself.
        capture.onButton = { button, down in
            if let listener = model.controllerListener {
                if down {
                    listener(button)
                }
                return true
            }
            if button == .options {
                if down {
                    Task { await pause() }
                }
                return true
            }
            return false
        }
        model.activeCapture = capture
        capture.onControllerCountChanged = { [weak capture] count in
            overlay.controllers = count
            OPLog.log(.ui, .info, "controllers connected: \(count) \(capture?.connectedNames ?? [])")
        }
        capture.start()
        OPLog.log(
            .ui,
            .info,
            "touch controls visible=\(overlay.padVisible) opacity=\(controlsOpacity) controllers=\(overlay.controllers)"
        )
        self.capture = capture
    }

    /// Starts the runtime, with the "Starting…" note when that takes over a second.
    func launch() async {
        let startingNote = Task {
            try await Task.sleep(for: .seconds(1))
            withAnimation(reduceMotion ? nil : Theme.quick) { starting = true }
        }
        defer {
            startingNote.cancel()
            starting = false
        }
        do {
            _ = try await model.play(game, snapshot: snapshot, host: host)
            OPLog.log(.ui, .info, "launch timing: runtime started after \(Self.ms(since: startedAt)) ms")
            if let line = model.launchNotice {
                withAnimation(reduceMotion ? nil : Theme.quick) { notice = line }
                Task {
                    try? await Task.sleep(for: .seconds(6))
                    withAnimation(reduceMotion ? nil : Theme.quick) { notice = nil }
                }
            }
            #if DEBUG
                if let delay = DebugLaunch.probeStateDelay {
                    Task {
                        try? await Task.sleep(for: .seconds(delay))
                        await model.probeState()
                    }
                }
                if DebugLaunch.openPauseMenu {
                    try? await Task.sleep(for: .seconds(2))
                    await pause()
                }
            #endif
            overlay.speed = await model.speedChoices
            overlay.engineMenu = await model.engineMenuTitle
            // A retry on a sibling runtime that plays through the boot window becomes this game's runtime.
            if model.pendingFallback[game.id] != nil {
                Task {
                    try? await Task.sleep(for: FallbackPolicy.bootWindow)
                    if failure == nil, !leaving, model.playing?.id == game.id {
                        await model.fallbackSucceeded(for: game.id)
                    }
                }
            }
        } catch let error as CoordinatorError {
            fail(Self.describe(error), category: .engineRefusedContent)
        } catch is CancellationError {
            // Left while media was being prepared; the screen is already on its way out.
        } catch {
            fail(error.localizedDescription, category: .engineRefusedContent)
        }
    }

    /// A failure at boot gets one retry on a sibling runtime (`FallbackPolicy`); anything else, or a second failure,
    /// is shown to the player.
    func fail(_ message: String, category: FailureCategory) {
        Task {
            let elapsed = ContinuousClock.now - startedAt
            if !leaving, let runtime = await model.fallbackCandidate(for: game, snapshot: snapshot, failure: category, elapsed: elapsed) {
                withAnimation(reduceMotion ? nil : Theme.quick) {
                    notice = "Trying a compatible runtime (\(DetectionExplainer.name(runtime)))…"
                }
                await model.stopPlaying(reason: .crash(detail: message))
                await start()
                return
            }
            model.fallbackFailed(for: game.id)
            notice = nil
            failure = message
            overlay.failed = true
        }
    }

    /// The touch controls live inside the runtime host's overlay, not in a SwiftUI overlay on this screen.
    /// The overlay follows the picture: a native engine opens its own `UIWindow` above the app's, and anything
    /// left in the SwiftUI layer ends up behind it — visible in a screenshot only because the engine's window
    /// is what you are actually looking at.
    func installControls() {
        let surface = ControlsPassthroughView()
        surface.backgroundColor = .clear
        surface.translatesAutoresizingMaskIntoConstraints = false
        let controller = UIHostingController(rootView: OverlayControls(
            overlay: overlay,
            onHitRegions: { [weak surface] regions in surface?.regions = regions },
            onEditControls: { Task { await editControls() } },
            onFastForward: { multiplier in Task { await model.setFastForward(multiplier) } },
            send: { model.send($0) }
        ))
        controller.view.backgroundColor = .clear
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        host.addChild(controller)
        host.overlayView.insertSubview(surface, at: 0)
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
        controls = controller
        controlsSurface = surface
    }

    func removeControls() {
        controls?.willMove(toParent: nil)
        controls?.view.removeFromSuperview()
        controls?.removeFromParent()
        controlsSurface?.removeFromSuperview()
        controls = nil
        controlsSurface = nil
    }

    func pause() async {
        guard !overlay.paused, !leaving else { return }
        // Removing the input views releases any held key, modifier or mouse button before resuming later.
        overlay.paused = true
        await model.pause()
        // The menu brings its own entrance; the system slide would fight it.
        withTransaction(\.disablesAnimations, true) { menuShown = true }
        // The menu opens at once; the game's frame, blurred once off the main thread, fades in behind it.
        let frame = host.frozenFrameView.isHidden ? await model.captureScreen() : host.frozenFrameView.image?.cgImage
        pausedFrame = await Task.detached { PauseBackdrop.make(frame) }.value
    }

    static func ms(since start: ContinuousClock.Instant) -> Int {
        let d = (ContinuousClock.now - start).components
        return Int(d.seconds * 1000 + d.attoseconds / 1_000_000_000_000_000)
    }

    static func played(since start: ContinuousClock.Instant) -> String {
        let minutes = Int((ContinuousClock.now - start).components.seconds / 60)
        return minutes < 1 ? "just started" : "\(minutes) min played"
    }

    func resume() async {
        guard !leaving else { return }
        pausedFrame = nil
        await model.resume()
        overlay.paused = false
    }

    func leave() async {
        guard !leaving else { return }
        leaving = true
        model.cancelMediaPreparation()
        closeMenu()
        capture?.stop()
        removeControls()
        await model.stopPlaying()
        if let warning = model.saveWarning {
            failure = warning
            model.saveWarning = nil
        } else {
            dismiss()
        }
    }

    static func describe(_ error: CoordinatorError) -> String {
        switch error {
        case .busy: "Another game is still closing. Try again in a moment."
        case let .preflight(p):
            switch p {
            case .ok: "Ready."
            case .slotBusy: "Another game is running."
            case .slotSpent:
                "This engine runs one game per app launch. Use Save & Relaunch on the game's page, or close OmniPlay and open it again."
            case let .notBuilt(r): "The \(DetectionExplainer.name(r)) runtime is not part of this build."
            case let .noRuntime(reason): reason
            }
        case let .prepareFailed(d): "Preparing the game failed: \(d)"
        case let .startFailed(d): "Starting the game failed: \(d)"
        }
    }
}
