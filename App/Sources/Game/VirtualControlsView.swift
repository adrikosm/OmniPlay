import InputKit
import SwiftUI
import UIKit

/// Touch controls over the game: a round glass D-pad and the face buttons, laid out per orientation from a
/// `ControlsLayout`. Every control is at least 44 pt, presses give a light tap, and empty space passes through.
struct VirtualControlsView: View {
    let opacity: Double
    /// The game's own layouts (a JoiPlay package's, later the player's); the built-in ones otherwise.
    var layouts: ControlsLayoutSet?
    let send: (GameInputEvent) -> Void

    var body: some View {
        GeometryReader { geo in
            let layout = geo.size.width > geo.size.height
                ? layouts?.landscape ?? ControlsLayout.landscape : layouts?.portrait ?? ControlsLayout.portrait
            ZStack(alignment: .topLeading) {
                DPad(size: layout.dpad.size, send: send)
                    .gameControlHitRegion()
                    .position(layout.dpad.center(in: geo.size))
                ForEach(layout.buttons) { control in
                    KeyButton(control: control, send: send)
                        .gameControlHitRegion()
                        .position(control.anchor.center(in: geo.size))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .opacity(opacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Touch controls")
    }
}

/// The glass the pad is made of: blur and a dark cool tint, a hairline, a light top edge and a soft drop shadow,
/// so it reads over a white title screen and a black dungeon alike. `lit` brightens it while pressed.
struct PadGlass: ViewModifier {
    var lit = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    if reduceTransparency {
                        Circle().fill(Theme.glassTint.opacity(0.92))
                    } else {
                        Circle().fill(.ultraThinMaterial)
                        Circle().fill(Theme.glassTint.opacity(0.5))
                    }
                    Circle().fill(Theme.edge.opacity(lit ? 0.4 : 0))
                }
                .shadow(color: .black.opacity(0.4), radius: 15, y: 10)
            }
            .overlay {
                Circle().strokeBorder(Theme.edge.opacity(0.24), lineWidth: 1)
                    .mask(alignment: .top) {
                        LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom).frame(height: 10)
                    }
            }
            .overlay { Circle().strokeBorder(Theme.edge.opacity(0.2), lineWidth: 0.5) }
    }
}

extension View {
    func padGlass(lit: Bool = false) -> some View { modifier(PadGlass(lit: lit)) }
}

/// One key: hold to keep it down. Two-finger play works because each button tracks its own touch.
/// A press shrinks the button and lights it; letting go springs it back. Displays the assigned keybinding dynamically.
private struct KeyButton: View {
    let control: ControlsLayout.Control
    let send: (GameInputEvent) -> Void
    @State private var down = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var labelText: String {
        control.effectiveLabel
    }

    var body: some View {
        Text(labelText)
            .font(.system(size: min(18, control.anchor.size * 0.34), weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, 4)
            .foregroundStyle(Theme.textPrimary)
            .frame(width: control.anchor.size, height: control.anchor.size)
            .padGlass(lit: down)
            .scaleEffect(down && !reduceMotion ? 0.86 : 1)
            .animation(.spring(response: down ? 0.08 : 0.25, dampingFraction: down ? 0.9 : 0.55), value: down)
            .overlay(alignment: .topTrailing) {
                if control.hold == true {
                    Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textSecondary)
                        .offset(x: -control.anchor.size * 0.12, y: control.anchor.size * 0.12)
                }
            }
            .contentShape(.circle)
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in
                if control.hold != true {
                    press(true)
                }
            }.onEnded { _ in
                // A hold button flips on each tap; the others follow the finger.
                press(control.hold == true ? !down : false)
            })
            .accessibilityLabel(labelText)
            .accessibilityAddTraits(control.hold == true && down ? [.isButton, .isSelected] : .isButton)
            .accessibilityValue(control.hold == true ? (down ? "Held" : "Released") : "")
            .accessibilityAction {
                if control.hold == true {
                    press(!down)
                } else {
                    press(true)
                    press(false)
                }
            }
            // A latched key must not stay down in the game once its button is gone.
            .onDisappear { press(false) }
    }

    private func press(_ next: Bool) {
        guard next != down else { return }
        down = next
        if next {
            Haptics.tap()
        }
        for key in control.keys {
            send(next ? .keyDown(key) : .keyUp(key))
        }
    }
}

/// An ultra-responsive virtual joystick and directional control: supports continuous press-and-drag
/// with smooth tracking from the touch origin, tight deadzone handling, clamped maximum radius,
/// analog velocity updates (controllerAxis), and instant 8-way directional key dispatch, plus discrete taps.
private struct DPad: View {
    let size: Double
    let send: (GameInputEvent) -> Void
    @State private var held: Set<GameKey> = []
    @State private var knobOffset: CGSize = .zero
    @State private var isTouching = false
    @State private var touchOrigin: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let deadzone: Double = 6.0

    private var maxRadius: Double {
        size * 0.42
    }

    var body: some View {
        let activeTilt = tilt
        ZStack {
            // Glass base disc
            Circle().fill(Color.clear).padGlass()

            // Direction chevrons that highlight and scale when active
            ForEach(Self.arms, id: \.key.rawValue) { arm in
                let lit = held.contains(arm.key)
                Image(systemName: arm.symbol)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.textPrimary.opacity(lit ? 1.0 : 0.65))
                    .scaleEffect(lit ? 1.22 : 1.0)
                    .offset(x: arm.dx * size * 0.28, y: arm.dy * size * 0.28)
                    .animation(.spring(response: 0.12, dampingFraction: 0.7), value: lit)
            }

            // Visual thumb knob that smoothly follows thumb drag with maximum radius clamping
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Theme.edge.opacity(isTouching ? 0.45 : 0.2),
                            Theme.glassTint.opacity(isTouching ? 0.95 : 0.7),
                        ],
                        center: .center,
                        startRadius: 2,
                        endRadius: 24
                    )
                )
                .frame(width: 48, height: 48)
                .overlay {
                    Circle().strokeBorder(Theme.edge.opacity(isTouching ? 0.6 : 0.3), lineWidth: 1)
                }
                .overlay {
                    Circle()
                        .fill(Theme.textPrimary.opacity(isTouching ? 0.8 : 0.4))
                        .frame(width: 8, height: 8)
                }
                .shadow(color: .black.opacity(0.4), radius: isTouching ? 10 : 5, y: isTouching ? 6 : 3)
                .offset(x: knobOffset.width, y: knobOffset.height)
                .animation(
                    isTouching
                        ? .interactiveSpring(response: 0.06, dampingFraction: 0.82)
                        : .spring(response: 0.22, dampingFraction: 0.7),
                    value: knobOffset
                )
        }
        .frame(width: size, height: size)
        .rotation3DEffect(
            .degrees(held.isEmpty || reduceMotion ? 0 : 7),
            axis: (x: -activeTilt.dy, y: activeTilt.dx, z: 0),
            perspective: 0.6
        )
        .contentShape(.circle)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    updateTouch(start: value.startLocation, current: value.location, translation: value.translation)
                }
                .onEnded { _ in
                    endTouch()
                }
        )
        .onDisappear { endTouch() }
        .accessibilityLabel("Movement controls")
        .accessibilityElement(children: .ignore)
        .accessibilityAction(named: "Move up") { tap(.arrowUp) }
        .accessibilityAction(named: "Move down") { tap(.arrowDown) }
        .accessibilityAction(named: "Move left") { tap(.arrowLeft) }
        .accessibilityAction(named: "Move right") { tap(.arrowRight) }
    }

    private var tilt: (dx: Double, dy: Double) {
        if knobOffset == .zero { return (0, 0) }
        let len = max(hypot(knobOffset.width, knobOffset.height), 1)
        return (knobOffset.width / len, knobOffset.height / len)
    }

    private struct Arm { let key: GameKey; let symbol: String; let dx: Double; let dy: Double }
    private static let arms = [
        Arm(key: .arrowUp, symbol: "chevron.up", dx: 0, dy: -1),
        Arm(key: .arrowDown, symbol: "chevron.down", dx: 0, dy: 1),
        Arm(key: .arrowLeft, symbol: "chevron.left", dx: -1, dy: 0),
        Arm(key: .arrowRight, symbol: "chevron.right", dx: 1, dy: 0),
    ]

    private func updateTouch(start: CGPoint, current: CGPoint, translation: CGSize) {
        let center = CGPoint(x: size / 2, y: size / 2)
        if !isTouching {
            isTouching = true
            let startDist = hypot(start.x - center.x, start.y - center.y)
            // If touch lands near the outer edge/chevron, track from center for an instant discrete tap;
            // if touch lands in the inner thumb region, track drag directly from the touch origin.
            touchOrigin = startDist > size * 0.22 ? center : start
        }

        let origin = touchOrigin ?? center
        let rawDx = current.x - origin.x
        let rawDy = current.y - origin.y
        let rawDist = hypot(rawDx, rawDy)

        var vectorX: Double = 0
        var vectorY: Double = 0
        var wanted: Set<GameKey> = []

        if rawDist > Self.deadzone {
            let clampedDist = min(rawDist, maxRadius)
            let unitX = rawDx / rawDist
            let unitY = rawDy / rawDist

            // Increased movement sensitivity: reach full velocity promptly
            let normalizedMagnitude = (clampedDist - Self.deadzone) / (maxRadius - Self.deadzone)
            let sensitivity = min(1.0, normalizedMagnitude * 1.35)

            vectorX = unitX * sensitivity
            vectorY = unitY * sensitivity

            knobOffset = CGSize(width: unitX * clampedDist, height: unitY * clampedDist)

            // 8 sectors centered on cardinal & diagonal angles
            let deg = atan2(rawDy, rawDx) * 180.0 / .pi
            let normalizedDeg = deg < 0 ? deg + 360.0 : deg
            let sector = Int((normalizedDeg + 22.5) / 45.0) % 8
            wanted = [
                [.arrowRight],
                [.arrowRight, .arrowDown],
                [.arrowDown],
                [.arrowDown, .arrowLeft],
                [.arrowLeft],
                [.arrowLeft, .arrowUp],
                [.arrowUp],
                [.arrowUp, .arrowRight],
            ][sector]
        } else {
            knobOffset = .zero
        }

        // Apply directional vector instantly to velocity / analog axes
        // GameController convention: Y is positive up, negative down
        send(.controllerAxis(.leftX, value: Float(vectorX)))
        send(.controllerAxis(.leftY, value: Float(-vectorY)))

        // Dispatch key events if directions changed
        if wanted != held {
            if !wanted.isEmpty && held.isEmpty {
                Haptics.tap()
            }
            for key in held.subtracting(wanted) {
                send(.keyUp(key))
            }
            for key in wanted.subtracting(held) {
                send(.keyDown(key))
            }
            held = wanted
        }
    }

    private func endTouch() {
        isTouching = false
        touchOrigin = nil
        knobOffset = .zero

        send(.controllerAxis(.leftX, value: 0))
        send(.controllerAxis(.leftY, value: 0))

        for key in held {
            send(.keyUp(key))
        }
        held.removeAll()
    }

    private func tap(_ key: GameKey) {
        endTouch()
        Haptics.tap()
        send(.keyDown(key))
        send(.keyUp(key))
    }
}

extension ControlsLayout.Anchor {
    /// Both the editor and live pad use the safe-area canvas; keep the entire target inside it after a drag or rotation.
    func center(in canvas: CGSize) -> CGPoint {
        let insetX = min(size / 2, canvas.width / 2)
        let insetY = min(size / 2, canvas.height / 2)
        return CGPoint(
            x: min(max(canvas.width * x, insetX), canvas.width - insetX),
            y: min(max(canvas.height * y, insetY), canvas.height - insetY)
        )
    }
}

/// Presses answer with a tap whose strength the player sets in the pause menu; 0 turns them off.
@MainActor
enum Haptics {
    static let intensityKey = "omniplay.controls.haptics"
    private static let generator = UIImpactFeedbackGenerator(style: .light)
    static func tap() {
        let intensity = UserDefaults.standard.object(forKey: intensityKey) as? Double ?? 0.7
        if intensity > 0 {
            generator.impactOccurred(intensity: intensity)
        }
    }
}
