import InputKit
import SwiftUI

/// Edits the touch controls over the paused game. The pad wiggles like home-screen icons in edit mode: drag a control
/// to move it (snapped to a grid), pinch to resize it. The side panel picks Diamond, Row or Hidden, remaps the four
/// face buttons, and sets opacity and whether a controller hides the pad. Touch and hold a control to latch, copy or
/// delete it; ••• has undo, reset, add and discard. Done saves the pair as the game's own layout.
struct ControlsEditorView: View {
    let onDone: (ControlsLayoutSet) -> Void
    let onCancel: () -> Void
    @Binding var padVisible: Bool
    @State var set: ControlsLayoutSet
    @State var history: [ControlsLayoutSet] = []
    @State var selected: String?
    @State var dragging: String?
    @State var dragStart: ControlsLayout.Anchor?
    @State var pinchStart: Double?
    @State var panelIn = false
    @State var wiggle = false
    @AppStorage("omniplay.controls.opacity") var opacity = 0.8
    @AppStorage("omniplay.controls.hideWithController") var hideWithController = true
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    static let dpadID = "dpad"
    /// The game's engine default, for Reset.
    let builtIn: ControlsLayoutSet

    init(
        layouts: ControlsLayoutSet?,
        builtIn: ControlsLayoutSet,
        padVisible: Binding<Bool>,
        onDone: @escaping (ControlsLayoutSet) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _set = State(initialValue: layouts ?? builtIn)
        self.builtIn = builtIn
        _padVisible = padVisible
        self.onDone = onDone
        self.onCancel = onCancel
    }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let canvas = Canvas(size: geo.size, landscape: landscape)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .contentShape(.rect)
                    .onTapGesture { selected = nil }
                pad(landscape: landscape, canvas: canvas)
                    .frame(width: geo.size.width, height: geo.size.height)
                if panelIn {
                    panel(landscape: landscape, full: geo.size)
                        .frame(
                            width: landscape ? 350 : geo.size.width - 24,
                            height: landscape ? geo.size.height - 12 : geo.size.height * 0.54 - 12
                        )
                        .glass(radius: Theme.panelRadius, heavy: true)
                        .padding(landscape ? .trailing : .bottom, 12)
                        .padding(.top, landscape ? 6 : 0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: landscape ? .topTrailing : .bottom)
                        .transition(reduceMotion ? .opacity : .move(edge: landscape ? .trailing : .bottom).combined(with: .opacity))
                }
            }
        }
        .onAppear {
            withAnimation(Theme.motion(Theme.sheet, reduce: reduceMotion)) { panelIn = true }
            wiggle = !reduceMotion
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Controls editor")
    }

    // MARK: Pad

    func pad(landscape: Bool, canvas: Canvas) -> some View {
        let layout = current(landscape)
        return ZStack(alignment: .topLeading) {
            Color.clear.contentShape(.rect).onTapGesture { selected = nil }
            handle(Self.dpadID, label: nil, anchor: layout.dpad, index: 0, landscape: landscape, canvas: canvas)
            ForEach(Array(layout.buttons.enumerated()), id: \.element.id) { index, control in
                handle(control.id, label: control.label, anchor: control.anchor, index: index + 1, landscape: landscape, canvas: canvas)
            }
        }
        .opacity(padVisible ? 1 : 0.3)
        .gesture(MagnifyGesture().onChanged { value in
            guard let id = selected ?? dragging, let anchor = current(landscape).anchor(target(id)) else { return }
            if pinchStart == nil {
                pinchStart = anchor.size
                remember()
            }
            edit(landscape) { $0.resize(target(id), to: (pinchStart ?? anchor.size) * value.magnification) }
        }.onEnded { _ in pinchStart = nil })
    }

    /// One control as the editor shows it: the live look, a dashed outline, a gentle wiggle. Selected ones get a
    /// solid ring; a dragged one lifts and stops wiggling.
    func handle(
        _ id: String,
        label: String?,
        anchor: ControlsLayout.Anchor,
        index: Int,
        landscape: Bool,
        canvas: Canvas
    ) -> some View {
        let isSelected = selected == id
        let lifted = dragging == id
        let hold = current(landscape).buttons.first { $0.id == id }?.hold == true
        return Group {
            if let label {
                Text(label)
                    .font(.system(size: min(18, anchor.size * 0.34), weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.6).padding(.horizontal, 4)
                    .foregroundStyle(Theme.textPrimary)
            } else {
                ZStack {
                    ForEach(
                        [("chevron.up", 0.0, -1.0), ("chevron.down", 0, 1), ("chevron.left", -1, 0), ("chevron.right", 1, 0)],
                        id: \.0
                    ) { arm in
                        Image(systemName: arm.0).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.textPrimary.opacity(0.82))
                            .offset(x: arm.1 * anchor.size * 0.265, y: arm.2 * anchor.size * 0.265)
                    }
                }
            }
        }
        .frame(width: anchor.size, height: anchor.size)
        .padGlass(lit: lifted)
        .overlay {
            Circle().inset(by: -4)
                .stroke(
                    isSelected ? Theme.textPrimary : Theme.edge.opacity(0.6),
                    style: StrokeStyle(lineWidth: isSelected ? 2 : 1.5, dash: isSelected ? [] : [4, 3])
                )
        }
        .overlay(alignment: .topTrailing) {
            if hold {
                Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textSecondary)
                    .offset(x: -anchor.size * 0.12, y: anchor.size * 0.12)
            }
        }
        .rotationEffect(.degrees(wiggle && !lifted && padVisible ? (index.isMultiple(of: 2) ? 2.5 : -2.5) : 0))
        .animation(
            wiggle && !lifted ? .easeInOut(duration: 0.28).repeatForever(autoreverses: true).delay(Double(index % 4) * 0.05) : .default,
            value: wiggle && !lifted
        )
        .scaleEffect(lifted ? 1.08 : 1)
        .animation(Theme.press, value: lifted)
        .contentShape(.circle)
        .position(canvas.place(anchor))
        .onTapGesture { selected = id }
        .gesture(DragGesture(minimumDistance: 4).onChanged { value in
            if dragStart == nil {
                dragStart = anchor
                dragging = id
                selected = id
                remember()
            }
            guard let start = dragStart else { return }
            let from = canvas.place(start)
            let unit = canvas.unit(CGPoint(x: from.x + value.translation.width, y: from.y + value.translation.height))
            edit(landscape) { $0.move(target(id), to: unit.x, unit.y) }
        }.onEnded { _ in
            dragStart = nil
            dragging = nil
        })
        .sensoryFeedback(.selection, trigger: dragging == id)
        .contextMenu {
            if id != Self.dpadID {
                Group {
                    Button(hold ? "Stop latching" : "Latch on tap", systemImage: hold ? "lock.open" : "lock") {
                        remember()
                        edit(landscape) { $0.setHold(!hold, for: id) }
                    }
                    Button("Duplicate", systemImage: "plus.square.on.square") {
                        remember()
                        var copy: String?
                        edit(landscape) { copy = $0.duplicate(id) }
                        selected = copy
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        remember()
                        edit(landscape) { $0.remove(id) }
                        selected = nil
                    }
                }
                .tint(Theme.textPrimary)
            }
        }
        .accessibilityLabel(label ?? "D-pad")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Where the pad is drawn while the panel is open. Controls keep their true size and spacing; the side of the
    /// screen under the panel slides clear of it, ramping across the middle so nothing jumps while it is dragged.
    /// The ramp ends at 70% across, so the face buttons on the right keep their spacing in every arrangement.
    struct Canvas {
        let size: CGSize
        let landscape: Bool
        /// How far the far side moves: the panel's width in landscape, its height in portrait.
        var shift: Double { landscape ? 374 : size.height * 0.54 }

        private func ramp(_ unit: Double) -> Double { min(max((unit - 0.1) / 0.6, 0), 1) }

        func place(_ anchor: ControlsLayout.Anchor) -> CGPoint {
            let actual = anchor.center(in: size)
            return landscape
                ? CGPoint(x: actual.x - shift * ramp(anchor.x), y: actual.y)
                : CGPoint(x: actual.x, y: actual.y - shift * ramp(anchor.y))
        }

        /// The unit position that `place` draws at `point` (the mapping only grows, so halving the range finds it).
        func unit(_ point: CGPoint) -> (x: Double, y: Double) {
            func solve(_ target: Double, length: Double, shifted: Bool) -> Double {
                guard shifted else { return target / length }
                var (low, high) = (-0.2, 1.2)
                for _ in 0 ..< 40 {
                    let mid = (low + high) / 2
                    if mid * length - shift * ramp(mid) < target {
                        low = mid
                    } else {
                        high = mid
                    }
                }
                return (low + high) / 2
            }
            return (solve(point.x, length: size.width, shifted: landscape), solve(point.y, length: size.height, shifted: !landscape))
        }
    }
}
