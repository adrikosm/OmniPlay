import InputKit
import SwiftUI
import UIKit

/// Touch controls over the game: an 8-way D-pad and RPG Maker's six keys, laid out per orientation from a
/// `ControlsLayout`. Every control is at least 44 pt, presses give a light tap, and empty space passes through.
struct VirtualControlsView: View {
    let opacity: Double
    let send: (GameInputEvent) -> Void

    var body: some View {
        GeometryReader { geo in
            let layout = geo.size.width > geo.size.height ? ControlsLayout.landscape : ControlsLayout.portrait
            ZStack(alignment: .topLeading) {
                DPad(size: layout.dpad.size, send: send)
                    .position(x: geo.size.width * layout.dpad.x, y: geo.size.height * layout.dpad.y)
                ForEach(layout.buttons) { control in
                    KeyButton(control: control, send: send)
                        .position(x: geo.size.width * control.anchor.x, y: geo.size.height * control.anchor.y)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .opacity(opacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Touch controls")
    }
}

/// One key: hold to keep it down. Two-finger play works because each button tracks its own touch.
private struct KeyButton: View {
    let control: ControlsLayout.Control
    let send: (GameInputEvent) -> Void
    @State private var down = false

    var body: some View {
        Text(control.label)
            .font(.system(size: control.anchor.size > 56 ? 15 : 12, weight: .semibold, design: .rounded))
            .foregroundStyle(down ? Theme.ink : Theme.textPrimary)
            .frame(width: control.anchor.size, height: control.anchor.size)
            .background(down ? Theme.lantern : Color.white.opacity(0.10), in: .circle)
            .overlay(Circle().strokeBorder(down ? Theme.lantern : Color.white.opacity(0.28), lineWidth: 1.5))
            .contentShape(.circle)
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in press(true) }.onEnded { _ in press(false) })
            .accessibilityLabel(control.label)
            .accessibilityAddTraits(.isButton)
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

/// Eight directions from the touch angle, with a dead centre. Diagonals hold two arrows.
private struct DPad: View {
    let size: Double
    let send: (GameInputEvent) -> Void
    @State private var held: Set<GameKey> = []

    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.08))
            Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 1.5)
            ForEach(Self.arms, id: \.key.rawValue) { arm in
                Image(systemName: arm.symbol)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(held.contains(arm.key) ? Theme.lantern : Theme.textPrimary)
                    .offset(x: arm.dx * size * 0.32, y: arm.dy * size * 0.32)
            }
            Circle().fill(Color.white.opacity(held.isEmpty ? 0.10 : 0.22)).frame(width: size * 0.26, height: size * 0.26)
        }
        .frame(width: size, height: size)
        .contentShape(.circle)
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in update(value.location) }.onEnded { _ in update(nil) })
        .accessibilityLabel("Direction pad")
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
        if held.isEmpty, !wanted.isEmpty {
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

@MainActor
enum Haptics {
    private static let generator = UIImpactFeedbackGenerator(style: .light)
    static func tap() { generator.impactOccurred(intensity: 0.7) }
}
