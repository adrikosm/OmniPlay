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
        public let overlayView = UIView()
        public var onEvent: (@MainActor (RuntimeEvent) -> Void)?
        public var onExitRequested: (@MainActor () -> Void)?

        public init(sessionID: SessionID, orientation: OrientationPreference) {
            self.sessionID = sessionID
            orientationPreference = orientation
            super.init(nibName: nil, bundle: nil)
            modalPresentationStyle = .fullScreen
        }

        @available(*, unavailable) required init?(coder: NSCoder) { nil }

        override public func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            containerView.backgroundColor = .black
            containerView.translatesAutoresizingMaskIntoConstraints = false
            overlayView.translatesAutoresizingMaskIntoConstraints = false
            overlayView.isUserInteractionEnabled = true
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
            overlayView.addSubview(exitButton)
            NSLayoutConstraint.activate([
                exitButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
                exitButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
                exitButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
                exitButton.heightAnchor.constraint(equalToConstant: 44),
            ])
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

        /// Pass-through for the overlay: only the exit control catches touches; the rest reaches the game.
        private lazy var exitButton: UIButton = {
            var config = UIButton.Configuration.glass()
            config.image = UIImage(systemName: "xmark")
            let b = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.onExitRequested?() })
            b.translatesAutoresizingMaskIntoConstraints = false
            b.accessibilityLabel = "Leave game"
            return b
        }()

        override public func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            overlayView.subviews.forEach { $0.isHidden = false }
        }
    }

#endif
