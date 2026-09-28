import CoreImage
import InputKit
import RuntimeCore
import SwiftUI
import UIKit

/// What the in-game overlay needs to know while a session runs. Shared with the hosted controls, which live
/// in the runtime host's view hierarchy rather than in this screen's.
@Observable @MainActor
final class SessionOverlay {
    var controllers = 0
    var failed = false
    var paused = false
    var sceneActive = true
    /// The pause menu's speed row, when the runtime can go faster.
    var speed: SpeedChoices?
    /// The engine's own menu, reachable from the pause sheet, when it has one.
    var engineMenu: String?
    var fastForward = 1
    /// The engine reads the screen's touches directly (Ren'Py), so the virtual pad stays hidden.
    var touchNative = false
    /// A touch-native engine whose games may still want keys (Godot): the pad is offered, off by default.
    var padOptional = false
    var hasPad: Bool { !touchNative || padOptional }
    /// The game's own control layouts, when it has them.
    var layouts: ControlsLayoutSet?
    /// The layout editor is open, so the live controls step aside.
    var editing = false
    /// Touchpad mouse over the game, with its speed (INPUT-008).
    var touchpadSpeed: Double?
    /// The key strip is up (INPUT-009).
    var keyStrip = false
    /// The pad is shown for this game in this orientation. The choice is kept per game and orientation, so hiding it
    /// for a novel leaves an RPG's pad alone, and a portrait choice leaves landscape alone.
    var padVisible = true {
        didSet {
            if let key = storedKey, !loadingPad {
                UserDefaults.standard.set(padVisible, forKey: key)
            }
        }
    }

    /// The game's key prefix. Setting it loads the stored choice; only the player's own choice is stored, so an
    /// engine's default can still change later.
    var padKey: String? { didSet { loadPad() } }
    /// Which orientation's choice applies; the hosted controls set it from their size.
    var landscape = true {
        didSet {
            if landscape != oldValue {
                loadPad()
            }
        }
    }

    private var storedKey: String? { padKey.map { "\($0).\(landscape ? "landscape" : "portrait")" } }

    private func loadPad() {
        loadingPad = true
        let defaults = UserDefaults.standard
        // Before 26 Sep the choice was one per game; it still seeds both orientations.
        let stored = storedKey.flatMap { defaults.object(forKey: $0) as? Bool } ?? padKey.flatMap { defaults.object(forKey: $0) as? Bool }
        padVisible = stored ?? !padOptional
        loadingPad = false
    }

    private var loadingPad = false
}

/// The touch controls as the host overlay hosts them. Reads the same defaults the pause menu writes, so the
/// two stay in step without a binding crossing the hierarchy. Top right, beside the host's pause button: the key
/// strip and the controller icon, which opens the controls editor.
struct OverlayControls: View {
    let overlay: SessionOverlay
    let onHitRegions: ([CGRect]) -> Void
    let onEditControls: () -> Void
    let onFastForward: (Int) -> Void
    let send: (GameInputEvent) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("omniplay.controls.opacity") private var opacity = 0.8
    @AppStorage("omniplay.controls.hideWithController") private var hideWithController = true
    @AppStorage("omniplay.tip.editControls") private var tipShown = false
    @State private var tip = false
    /// A swipe on the buttons also ends as a tap on one of them; that tap is dropped.
    @State private var swipedAt: ContinuousClock.Instant?
    @State private var holdingSpeed = false

    private func unlessSwiped(_ action: () -> Void) {
        if swipedAt.map({ $0.duration(to: .now) > .milliseconds(300) }) ?? true {
            action()
        }
    }

    private var shows: Bool {
        overlay.padVisible && overlay.hasPad && (overlay.controllers == 0 || !hideWithController)
    }

    var body: some View {
        ZStack {
            if !overlay.failed, !overlay.editing, !overlay.paused, overlay.sceneActive {
                if let speed = overlay.touchpadSpeed {
                    TouchpadLayer(speed: speed, send: send).ignoresSafeArea().gameControlHitRegion()
                }
                if shows {
                    VirtualControlsView(opacity: opacity, layouts: overlay.layouts) { send($0) }
                        .ignoresSafeArea(.keyboard)
                        .transition(.opacity)
                }
                VStack(spacing: Theme.s2) {
                    HStack(spacing: 10) {
                        Spacer()
                        if let fastest = overlay.speed?.options.last?.value, fastest > 1 {
                            // Held: the fastest speed; let go: the speed chosen in Pause.
                            Image(systemName: "forward.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .frame(width: 44, height: 44)
                                .glass(Circle())
                                .overlay(Circle().fill(Theme.edge.opacity(holdingSpeed ? 0.18 : 0)))
                                .scaleEffect(holdingSpeed && !reduceMotion ? 0.9 : 1)
                                .animation(Theme.motion(Theme.press, reduce: reduceMotion), value: holdingSpeed)
                                .onLongPressGesture(minimumDuration: 0, maximumDistance: 60, perform: {}, onPressingChanged: { pressing in
                                    holdingSpeed = pressing
                                    onFastForward(pressing ? fastest : overlay.fastForward)
                                })
                                .gameControlHitRegion()
                                .accessibilityLabel("Fast forward while held")
                                .accessibilityAddTraits(.isButton)
                        }
                        if overlay.hasPad {
                            Button { unlessSwiped { overlay.padVisible.toggle() } } label: {
                                Image(systemName: overlay.padVisible ? "dpad.fill" : "dpad")
                            }
                            .buttonStyle(.round)
                            .gameControlHitRegion()
                            .accessibilityLabel(overlay.padVisible ? "Hide touch controls" : "Show touch controls")
                        }
                        Button { unlessSwiped { overlay.keyStrip.toggle() } } label: {
                            Image(systemName: overlay.keyStrip ? "keyboard.chevron.compact.down" : "keyboard")
                        }
                        .buttonStyle(.round)
                        .gameControlHitRegion()
                        .accessibilityLabel(overlay.keyStrip ? "Hide keys" : "Show keys")
                        .accessibilityValue(overlay.keyStrip ? "Shown" : "Hidden")
                        Button { unlessSwiped(onEditControls) } label: { Image(systemName: "gamecontroller") }
                            .buttonStyle(.round)
                            .gameControlHitRegion()
                            .accessibilityLabel("Edit touch controls")
                    }
                    // Room for the host's own pause button, which sits in the top-right corner.
                    .padding(.trailing, 54)
                    // Swipe down on the buttons to put the pad away, up to bring it back.
                    .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { drag in
                        guard overlay.hasPad, abs(drag.translation.height) > abs(drag.translation.width) else { return }
                        swipedAt = .now
                        overlay.padVisible = drag.translation.height < 0
                    })
                    if overlay.keyStrip {
                        KeyStripView(send: send)
                            .gameControlHitRegion()
                            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    }
                    Spacer()
                }
                .padding(.horizontal, Theme.s3)
                .padding(.top, 20)
                .animation(reduceMotion ? nil : Theme.quick, value: overlay.keyStrip)
                .overlay(alignment: .top) {
                    if tip {
                        Label("Tap the controller icon to edit buttons", systemImage: "gamecontroller")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, Theme.s4)
                            .frame(minHeight: 36)
                            .glass(Capsule())
                            .padding(.top, 24)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -8)))
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .onPreferenceChange(ControlHitRegions.self, perform: onHitRegions)
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { overlay.landscape = $0 }
        .animation(reduceMotion ? nil : Theme.quick, value: overlay.padVisible)
        .task {
            // Once per install, a moment after the game appears, then it fades.
            guard !tipShown, overlay.hasPad else { return }
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(Theme.motion(Theme.settle, reduce: reduceMotion)) { tip = true }
            tipShown = true
            try? await Task.sleep(for: .seconds(4))
            withAnimation(Theme.motion(.easeOut(duration: 0.6), reduce: reduceMotion)) { tip = false }
        }
    }
}

/// The hosting view fills the host, but only these actual controls may intercept the game's touches.
final class ControlsPassthroughView: UIView {
    var regions: [CGRect] = []

    override func point(inside point: CGPoint, with _: UIEvent?) -> Bool {
        regions.contains { $0.contains(point) }
    }
}

private struct ControlHitRegions: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

extension View {
    func gameControlHitRegion() -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: ControlHitRegions.self, value: [geometry.frame(in: .global)])
            }
        }
    }
}

/// A small, heavily blurred copy of the paused frame: made once per pause, so nothing live is ever blurred.
enum PauseBackdrop {
    nonisolated static func make(_ image: CGImage?) -> UIImage? {
        guard let image else { return nil }
        let source = CIImage(cgImage: image)
        let scale = 480 / max(source.extent.width, 1)
        let small = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 12).cropped(to: small.extent)
        return CIContext().createCGImage(blurred, from: small.extent).map { UIImage(cgImage: $0) }
    }
}
