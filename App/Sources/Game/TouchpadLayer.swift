import InputKit
import SwiftUI
import UIKit

/// Touchpad mouse (INPUT-008) over a game that reads a mouse: one finger moves a drawn cursor by its travel, a tap
/// clicks at the cursor, a two-finger tap right-clicks, and press-and-hold then move drags with the button down.
/// Points are the host view's, which is the game surface's own frame.
struct TouchpadLayer: UIViewRepresentable {
    let speed: Double
    let send: (GameInputEvent) -> Void

    func makeUIView(context _: Context) -> TouchpadView {
        let view = TouchpadView()
        view.speed = speed
        view.send = send
        return view
    }

    func updateUIView(_ view: TouchpadView, context _: Context) {
        view.speed = speed
        view.send = send
    }

    static func dismantleUIView(_ view: TouchpadView, coordinator _: ()) {
        view.releaseDrag()
    }
}

final class TouchpadView: UIView, UIGestureRecognizerDelegate {
    var speed = 1.0
    var send: (GameInputEvent) -> Void = { _ in }
    private var cursor: CGPoint?
    private var dragging = false
    private var lastPan = CGPoint.zero
    private var lastHold = CGPoint.zero
    private var laidOutSize = CGSize.zero
    private let arrow = UIImageView(image: UIImage(
        systemName: "cursorarrow",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
    ))

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        arrow.tintColor = .white
        arrow.layer.shadowColor = UIColor.black.cgColor
        arrow.layer.shadowOpacity = 0.8
        arrow.layer.shadowRadius = 1.5
        arrow.layer.shadowOffset = .zero
        arrow.isHidden = true
        addSubview(arrow)
        isAccessibilityElement = true
        accessibilityLabel = "Touchpad"
        accessibilityHint = "Move a finger to move the cursor, tap to click"

        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        let rightTap = UITapGestureRecognizer(target: self, action: #selector(rightTapped))
        rightTap.numberOfTouchesRequired = 2
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.35
        hold.allowableMovement = 10
        for recognizer in [pan, tap, rightTap, hold] {
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The view is laid out before the game's rotation settles: keep the cursor at the same relative spot.
        guard bounds.width > 0, bounds.height > 0, bounds.size != laidOutSize else { return }
        if let cursor, laidOutSize.width > 0 {
            place(CGPoint(x: cursor.x / laidOutSize.width * bounds.width, y: cursor.y / laidOutSize.height * bounds.height))
        } else {
            place(CGPoint(x: bounds.midX, y: bounds.midY))
        }
        laidOutSize = bounds.size
    }

    func gestureRecognizer(_: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool { true }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let point = pan.translation(in: self)
        if pan.state == .began {
            lastPan = .zero
        }
        guard !dragging, pan.state == .changed else { return }
        move(by: CGPoint(x: point.x - lastPan.x, y: point.y - lastPan.y))
        lastPan = point
    }

    @objc private func tapped() {
        guard let cursor else { return }
        send(.pointerDown(.primary, x: cursor.x, y: cursor.y))
        send(.pointerUp(.primary, x: cursor.x, y: cursor.y))
    }

    @objc private func rightTapped() {
        guard let cursor else { return }
        send(.pointerDown(.secondary, x: cursor.x, y: cursor.y))
        send(.pointerUp(.secondary, x: cursor.x, y: cursor.y))
    }

    @objc private func held(_ hold: UILongPressGestureRecognizer) {
        let point = hold.location(in: self)
        guard let cursor else { return }
        switch hold.state {
        case .began:
            dragging = true
            lastHold = point
            Haptics.tap()
            send(.pointerDown(.primary, x: cursor.x, y: cursor.y))
        case .changed:
            move(by: CGPoint(x: point.x - lastHold.x, y: point.y - lastHold.y))
            lastHold = point
        case .ended, .cancelled, .failed:
            releaseDrag()
        default:
            break
        }
    }

    func releaseDrag() {
        guard dragging, let cursor else { return }
        dragging = false
        send(.pointerUp(.primary, x: cursor.x, y: cursor.y))
    }

    private func move(by delta: CGPoint) {
        guard let cursor else { return }
        place(CGPoint(x: cursor.x + delta.x * speed, y: cursor.y + delta.y * speed))
        if let moved = self.cursor {
            send(.pointerMove(x: moved.x, y: moved.y))
        }
    }

    private func place(_ point: CGPoint) {
        let clamped = CGPoint(x: min(max(point.x, 0), bounds.width - 1), y: min(max(point.y, 0), bounds.height - 1))
        cursor = clamped
        arrow.isHidden = false
        // The arrow's tip is its top-left corner.
        arrow.frame.origin = CGPoint(x: clamped.x - 4, y: clamped.y - 3)
    }
}
