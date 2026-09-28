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
/// A press shrinks the button and lights it; letting go springs it back.
private struct KeyButton: View {
    let control: ControlsLayout.Control
    let send: (GameInputEvent) -> Void
    @State private var down = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(control.label)
            .font(.system(size: min(18, control.anchor.size * 0.34), weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 4)
            .foregroundStyle(Theme.textPrimary)
            .frame(width: control.anchor.size, height: control.anchor.size)
            .padGlass(lit: down)
            .scaleEffect(down && !reduceMotion ? 0.86 : 1)
            .animation(.spring(response: down ? 0.12 : 0.3, dampingFraction: down ? 0.9 : 0.55), value: down)
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
            .accessibilityLabel(control.label)
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

/// Eight directions from the touch angle, with a dead centre. Diagonals hold two arrows. The disc tips a few degrees
/// toward the thumb and the held arms light up, like a real pad rocking under a finger.
private struct DPad: View {
    let size: Double
    let send: (GameInputEvent) -> Void
    @State private var held: Set<GameKey> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tilt = direction
        ZStack {
            Circle().fill(Color.clear).padGlass()
            // Light pooling under the thumb.
            Circle()
                .fill(RadialGradient(
                    colors: [Theme.edge.opacity(0.32), Theme.edge.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: size * 0.3
                ))
                .frame(width: size * 0.6, height: size * 0.6)
                .offset(x: tilt.dx * size * 0.22, y: tilt.dy * size * 0.22)
                .opacity(held.isEmpty ? 0 : 1)
            ForEach(Self.arms, id: \.key.rawValue) { arm in
                let lit = held.contains(arm.key)
                Image(systemName: arm.symbol)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.textPrimary.opacity(lit ? 1 : 0.82))
                    .scaleEffect(lit ? 1.18 : 1)
                    .offset(x: arm.dx * size * 0.265, y: arm.dy * size * 0.265)
            }
        }
        .frame(width: size, height: size)
        .rotation3DEffect(.degrees(held.isEmpty || reduceMotion ? 0 : 9), axis: (x: -tilt.dy, y: tilt.dx, z: 0), perspective: 0.6)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: held)
        .contentShape(.circle)
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in update(value.location) }.onEnded { _ in update(nil) })
        // Hiding the pad mid-press must not leave the character walking.
        .onDisappear { update(nil) }
        .accessibilityLabel("Direction pad")
        .accessibilityElement(children: .ignore)
        .accessibilityAction(named: "Move up") { tap(.arrowUp) }
        .accessibilityAction(named: "Move down") { tap(.arrowDown) }
        .accessibilityAction(named: "Move left") { tap(.arrowLeft) }
        .accessibilityAction(named: "Move right") { tap(.arrowRight) }
    }

    /// The held direction as a unit vector (diagonals included), for the tilt and the light.
    private var direction: (dx: Double, dy: Double) {
        let arms = Self.arms.filter { held.contains($0.key) }
        let (x, y) = (arms.map(\.dx).reduce(0, +), arms.map(\.dy).reduce(0, +))
        let length = max(hypot(x, y), 1)
        return (x / length, y / length)
    }

    private struct Arm { let key: GameKey; let symbol: String; let dx: Double; let dy: Double }
    private static let arms = [
        Arm(key: .arrowUp, symbol: "chevron.up", dx: 0, dy: -1), Arm(key: .arrowDown, symbol: "chevron.down", dx: 0, dy: 1),
        Arm(key: .arrowLeft, symbol: "chevron.left", dx: -1, dy: 0), Arm(key: .arrowRight, symbol: "chevron.right", dx: 1, dy: 0),
    ]

    private func update(_ point: CGPoint?) {
        var wanted: Set<GameKey> = []
        if let point {
            let dx = point.x - size / 2, dy = point.y - size / 2
            if hypot(dx, dy) > size * 0.12 {
                // 8 sectors of 45°, centred on the four cardinal directions.
                let angle = atan2(-dy, dx)
                let sector = Int((angle / (.pi / 4)).rounded()) & 7
                wanted = [
                    [.arrowRight],
                    [.arrowRight, .arrowUp],
                    [.arrowUp],
                    [.arrowUp, .arrowLeft],
                    [.arrowLeft],
                    [.arrowLeft, .arrowDown],
                    [.arrowDown],
                    [.arrowDown, .arrowRight],
                ][sector]
            }
        }
        guard wanted != held else { return }
        if !wanted.isEmpty {
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

    private func tap(_ key: GameKey) {
        update(nil)
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
