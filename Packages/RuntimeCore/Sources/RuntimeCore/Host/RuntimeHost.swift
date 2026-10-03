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
        /// Contract rule 9: an engine's own key window draws above the app's, so the overlay moves into it.
        func adoptEngineWindow(_ window: UIWindow)
        func releaseEngineWindow()
        /// Hides the engine's window behind `image` (black when nil) so the host's sheets can be reached.
        func showFrozenFrame(_ image: CGImage?)
        func hideFrozenFrame()
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
        /// Transparent layer above the surface; only its subviews catch touches. It follows the picture: when an
        /// adapter hands over an engine-owned window it moves into that window, because that window draws above ours.
        public let overlayView = PassthroughView()
        /// The last frame the engine drew, shown while it is suspended. Opaque, so the engine's own window can be
        /// hidden behind it and the host's sheets become reachable again.
        public let frozenFrameView = UIImageView()
        /// A window an adapter's engine opened for itself (SDL's, for the native runtimes).
        public private(set) weak var engineWindow: UIWindow?
        public var onEvent: (@MainActor (RuntimeEvent) -> Void)?
        public var onPauseRequested: (@MainActor () -> Void)?
        /// Where the pause button sits, in unit coordinates of the safe area; persisted across sessions.
        static let positionKey = "omniplay.overlay.pausePosition"
        private var pausePosition = CGPoint(x: 0.96, y: 0.1)
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
            frozenFrameView.translatesAutoresizingMaskIntoConstraints = false
            frozenFrameView.contentMode = .scaleAspectFit
            frozenFrameView.backgroundColor = .black
            frozenFrameView.isHidden = true
            view.addSubview(containerView)
            view.addSubview(frozenFrameView)
            view.addSubview(overlayView)
            containerView.pinEdges(to: view)
            frozenFrameView.pinEdges(to: view)
            overlayView.pinEdges(to: view)
            overlayView.addSubview(pauseButton)
            // Anchored inside the overlay, not the host view: the overlay moves to an engine-owned window and a
            // constraint across two windows has no common ancestor to resolve against.
            let guide = overlayView.safeAreaLayoutGuide
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
            overlayView.onLayout = { [weak self] in self?.positionPauseButton() }
        }

        override public func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            positionPauseButton()
        }

        /// Puts the pause button away with the rest of the buttons over the game, or brings it back. It fades; while
        /// away it takes no touches, so the game gets them.
        public var pauseButtonHidden = false {
            didSet {
                guard pauseButtonHidden != oldValue else { return }
                let hidden = pauseButtonHidden
                if !hidden {
                    pauseButton.isHidden = false
                }
                UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                    self.pauseButton.alpha = hidden ? 0 : 1
                } completion: { _ in
                    if self.pauseButtonHidden {
                        self.pauseButton.isHidden = true
                    }
                }
            }
        }

        private func positionPauseButton() {
            let safe = overlayView.safeAreaLayoutGuide.layoutFrame
            guard safe.width > 0, safe.height > 0 else { return }
            // Kept whole inside the safe area: in landscape the top inset is zero and 4% of the height is less
            // than half the button, which left it hanging off the screen.
            let half = 22.0
            pauseCenterX?.constant = min(max(safe.width * pausePosition.x, half), safe.width - half)
            pauseCenterY?.constant = min(max(safe.height * pausePosition.y, half), safe.height - half)
        }

        @objc private func drag(_ pan: UIPanGestureRecognizer) {
            let safe = overlayView.safeAreaLayoutGuide.layoutFrame
            guard safe.width > 0, safe.height > 0 else { return }
            let point = pan.location(in: overlayView)
            pausePosition = CGPoint(
                x: ((point.x - safe.minX) / safe.width).clamped(0.04 ... 0.96),
                y: ((point.y - safe.minY) / safe.height).clamped(0.04 ... 0.96)
            )
            overlayView.setNeedsLayout()
            if pan.state == .ended || pan.state == .cancelled {
                UserDefaults.standard.set([pausePosition.x, pausePosition.y], forKey: Self.positionKey)
            }
        }

        override public func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            UIApplication.shared.isIdleTimerDisabled = true
        }

        override public func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            lockScene(to: supportedInterfaceOrientations)
        }

        override public func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            UIApplication.shared.isIdleTimerDisabled = false
            // A sheet over the game (the pause menu) lands here too; only leaving the game releases the lock.
            if sequence(first: self as UIViewController, next: \.parent).contains(where: { $0.isBeingDismissed || $0.isMovingFromParent }) {
                lockScene(to: .all)
            }
        }

        /// What the app delegate lets the scene rotate to. Inside a SwiftUI cover UIKit never asks a child
        /// controller for its orientations, so the game's lock is held app-wide while its session is on screen.
        public static var sceneOrientations: UIInterfaceOrientationMask = .all

        private func lockScene(to mask: UIInterfaceOrientationMask) {
            Self.sceneOrientations = mask
            var controller = view.window?.rootViewController
            while let current = controller {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller = current.presentedViewController
            }
            if mask != .all {
                view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
            }
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

        // MARK: Engine-owned windows

        /// SDL opens its own `UIWindow` and makes it key, so it sits above the app's. The overlay moves into it,
        /// which keeps the pause button and the touch controls on top of the picture instead of behind it.
        public func adoptEngineWindow(_ window: UIWindow) {
            engineWindow = window
            fit(window)
            pin(overlayView, into: window)
        }

        /// SDL tells its game the window's size whenever its view controller lays out, and a game re-creates its
        /// display at that size. A window put back into a scene keeps its old frame, and one hidden behind the
        /// frozen frame is laid out in portrait when the keyboard comes up for the tools; either way the game
        /// then drew in a corner. Sizing the window and SDL's root view from the scene reports the real size.
        private func fit(_ window: UIWindow) {
            if let scene = window.windowScene {
                window.frame = scene.coordinateSpace.bounds
            }
            window.rootViewController?.view.frame = window.bounds
            window.rootViewController?.view.layoutIfNeeded()
        }

        /// Gives the overlay back to the host's own view and hides the engine's window; called when the session
        /// ends. A hung engine's window must not stay over the library.
        public func releaseEngineWindow() {
            engineWindow?.isHidden = true
            engineWindow = nil
            pin(overlayView, into: view)
        }

        /// Shows a frozen frame and hides the engine's window, so the host's sheets are visible and touchable
        /// while the engine thread is suspended. `nil` shows black, which is still better than a live picture
        /// the player cannot reach past.
        public func showFrozenFrame(_ image: CGImage?) {
            frozenFrameView.image = image.map { UIImage(cgImage: $0) }
            frozenFrameView.isHidden = false
            pin(overlayView, into: view)
            engineWindow?.isHidden = true
        }

        public func hideFrozenFrame() {
            guard !frozenFrameView.isHidden else { return }
            frozenFrameView.isHidden = true
            frozenFrameView.image = nil
            if let engineWindow {
                engineWindow.isHidden = false
                fit(engineWindow)
                pin(overlayView, into: engineWindow)
            }
        }

        /// Child controllers whose views ride in the overlay (the touch controls) while it sits in an engine's window.
        private var detachedChildren: [UIViewController] = []

        /// Moves the overlay between the host's view and an engine's window. UIKit checks containment whenever a
        /// view changes windows and raises if a child controller's view ends up outside its parent's view, so the
        /// overlay's child controllers leave this controller before it enters an engine window and are adopted
        /// again, `addChild` first, before it comes back.
        private func pin(_ subview: UIView, into parent: UIView) {
            guard subview.superview !== parent else { return }
            let intoHost = parent.isDescendant(of: view)
            // Only the children still riding in the overlay come back: one removed meanwhile (the touch controls, taken
            // down as the player leaves) must not be adopted again.
            let returning = intoHost ? detachedChildren.filter { $0.view.isDescendant(of: subview) } : []
            if intoHost {
                for child in returning {
                    addChild(child)
                }
            } else {
                for child in children where child.view.isDescendant(of: subview) {
                    child.willMove(toParent: nil)
                    child.removeFromParent()
                    detachedChildren.append(child)
                }
            }
            subview.removeFromSuperview()
            subview.translatesAutoresizingMaskIntoConstraints = false
            parent.addSubview(subview)
            subview.pinEdges(to: parent)
            if intoHost {
                for child in returning {
                    child.didMove(toParent: self)
                }
                detachedChildren = []
            }
        }

        /// Glass like the touch controls (blur, a dark cool tint, a hairline); a tap pauses and opens the menu, a drag
        /// moves it. Pressing shrinks and lightens it.
        private lazy var pauseButton: UIButton = {
            var config = UIButton.Configuration.plain()
            config.image = UIImage(
                systemName: "pause.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            )
            config.baseForegroundColor = UIColor(red: 0.973, green: 0.980, blue: 0.988, alpha: 1)
            config.background.visualEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
            config.background.backgroundColor = UIColor(red: 18 / 255, green: 23 / 255, blue: 38 / 255, alpha: 0.5)
            config.background.strokeColor = UIColor(red: 200 / 255, green: 220 / 255, blue: 1, alpha: 0.2)
            config.background.strokeWidth = 0.5
            config.cornerStyle = .capsule
            let b = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.onPauseRequested?() })
            b.configurationUpdateHandler = { button in
                let pressed = button.isHighlighted
                UIView.animate(
                    withDuration: pressed ? 0.12 : 0.3,
                    delay: 0,
                    usingSpringWithDamping: pressed ? 1 : 0.6,
                    initialSpringVelocity: 0
                ) {
                    button.transform = pressed ? CGAffineTransform(scaleX: 0.9, y: 0.9) : .identity
                }
                button.configuration?.background.backgroundColor = pressed
                    ? UIColor(red: 200 / 255, green: 220 / 255, blue: 1, alpha: 0.3)
                    : UIColor(red: 18 / 255, green: 23 / 255, blue: 38 / 255, alpha: 0.5)
            }
            b.translatesAutoresizingMaskIntoConstraints = false
            b.layer.shadowColor = UIColor.black.cgColor
            b.layer.shadowOpacity = 0.4
            b.layer.shadowRadius = 15
            b.layer.shadowOffset = CGSize(width: 0, height: 10)
            b.accessibilityLabel = "Pause"
            b.accessibilityHint = "Opens the game menu. Drag to move."
            return b
        }()
    }

    /// Lets touches fall through to the surface unless a subview wants them.
    public final class PassthroughView: UIView {
        /// Called after every layout pass, including the ones an engine-owned window drives.
        public var onLayout: (@MainActor () -> Void)?

        override public func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let hit = super.hitTest(point, with: event)
            return hit === self ? nil : hit
        }

        override public func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }
    }

    extension UIView {
        /// Fills `parent` edge to edge. The caller has already turned off autoresizing-mask constraints.
        func pinEdges(to parent: UIView) {
            NSLayoutConstraint.activate([
                topAnchor.constraint(equalTo: parent.topAnchor),
                bottomAnchor.constraint(equalTo: parent.bottomAnchor),
                leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            ])
        }
    }

    private extension Double {
        func clamped(_ range: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
    }
#endif
