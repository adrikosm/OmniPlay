import Diagnostics
import Foundation
import GameCore

public enum OrientationPreference: String, Sendable, Codable { case any, landscape, portrait }

/// The shell-side object an adapter renders into and reports to. Lives on the main actor with the views.
@MainActor
public protocol RuntimeHost: AnyObject, Sendable {
    var sessionID: SessionID { get }
    var orientationPreference: OrientationPreference { get }
    func runtimeDidEmit(_ event: RuntimeEvent)
    #if canImport(UIKit)
        /// The view the adapter's surface fills edge to edge.
        var containerView: UIView { get }
    #endif
}

#if canImport(UIKit)
    import UIKit

    /// Full-screen container for a runtime surface: locks orientation per game, keeps the screen awake, reports
    /// safe areas, and hosts the overlay above the surface. Released with the session.
    public final class RuntimeHostViewController: UIViewController, RuntimeHost {
        public let sessionID: SessionID
        public let orientationPreference: OrientationPreference
        public let containerView = UIView()
        /// Transparent layer above the surface; only its subviews catch touches.
        public let overlayView = PassthroughView()
        public var onEvent: (@MainActor (RuntimeEvent) -> Void)?
        public var onPauseRequested: (@MainActor () -> Void)?
        /// Where the pause button sits, in unit coordinates of the safe area; persisted across sessions.
        static let positionKey = "omniplay.overlay.pausePosition"
        private var pausePosition = CGPoint(x: 0.96, y: 0.04)
        private var pauseCenterX: NSLayoutConstraint?
        private var pauseCenterY: NSLayoutConstraint?

        public init(sessionID: SessionID, orientation: OrientationPreference) {
            self.sessionID = sessionID
            orientationPreference = orientation
            super.init(nibName: nil, bundle: nil)
            modalPresentationStyle = .fullScreen
            if let stored = UserDefaults.standard.array(forKey: Self.positionKey) as? [Double], stored.count == 2 {
                pausePosition = CGPoint(x: stored[0].clamped(0.04 ... 0.96), y: stored[1].clamped(0.04 ... 0.96))
            }
        }

        @available(*, unavailable) required init?(coder: NSCoder) { nil }

        override public func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            containerView.backgroundColor = .black
            containerView.translatesAutoresizingMaskIntoConstraints = false
            overlayView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(containerView)
            view.addSubview(overlayView)
            NSLayoutConstraint.activate([
                containerView.topAnchor.constraint(equalTo: view.topAnchor),
                containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                overlayView.topAnchor.constraint(equalTo: view.topAnchor), overlayView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                overlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                overlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
            overlayView.addSubview(pauseButton)
            let guide = view.safeAreaLayoutGuide
            let x = pauseButton.centerXAnchor.constraint(equalTo: guide.leadingAnchor)
            let y = pauseButton.centerYAnchor.constraint(equalTo: guide.topAnchor)
            pauseCenterX = x
            pauseCenterY = y
            NSLayoutConstraint.activate([
                x,
                y,
                pauseButton.widthAnchor.constraint(equalToConstant: 44),
                pauseButton.heightAnchor.constraint(equalToConstant: 44),
            ])
            pauseButton.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))
        }

        override public func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            let safe = view.safeAreaLayoutGuide.layoutFrame
            pauseCenterX?.constant = safe.width * pausePosition.x
            pauseCenterY?.constant = safe.height * pausePosition.y
        }

        @objc private func drag(_ pan: UIPanGestureRecognizer) {
            let safe = view.safeAreaLayoutGuide.layoutFrame
            guard safe.width > 0, safe.height > 0 else { return }
            let point = pan.location(in: view)
            pausePosition = CGPoint(
                x: ((point.x - safe.minX) / safe.width).clamped(0.04 ... 0.96),
                y: ((point.y - safe.minY) / safe.height).clamped(0.04 ... 0.96)
            )
            view.setNeedsLayout()
            if pan.state == .ended || pan.state == .cancelled {
                UserDefaults.standard.set([pausePosition.x, pausePosition.y], forKey: Self.positionKey)
            }
        }

        override public func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            UIApplication.shared.isIdleTimerDisabled = true
        }

        override public func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            UIApplication.shared.isIdleTimerDisabled = false
        }

        override public var supportedInterfaceOrientations: UIInterfaceOrientationMask {
            switch orientationPreference {
            case .any: .all
            case .landscape: .landscape
            case .portrait: .portrait
            }
        }

        override public var prefersInterfaceOrientationLocked: Bool { orientationPreference != .any }
        override public var prefersStatusBarHidden: Bool { true }
        override public var prefersHomeIndicatorAutoHidden: Bool { true }

        public func runtimeDidEmit(_ event: RuntimeEvent) { onEvent?(event) }

        /// Semi-transparent glass control; a tap pauses and opens the menu, a drag moves it.
        private lazy var pauseButton: UIButton = {
            var config = UIButton.Configuration.glass()
            config.image = UIImage(systemName: "pause.fill")
            config.baseForegroundColor = .white
            let b = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.onPauseRequested?() })
            b.translatesAutoresizingMaskIntoConstraints = false
            b.alpha = 0.72
            b.accessibilityLabel = "Pause"
            b.accessibilityHint = "Opens the game menu. Drag to move."
            return b
        }()
    }

    /// Lets touches fall through to the surface unless a subview wants them.
    public final class PassthroughView: UIView {
        override public func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let hit = super.hitTest(point, with: event)
            return hit === self ? nil : hit
        }
    }

    private extension Double {
        func clamped(_ range: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
    }
#endif
