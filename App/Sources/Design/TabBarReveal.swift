import SwiftUI
import UIKit

extension View {
    /// Shows the tab bar again, if something left it hidden, each time `token` changes while `active`. A game's page
    /// hides the bar; SwiftUI can leave it hidden after the zoom back to the shelf (or after a game), and the library
    /// then had no way to the other tabs. A bar that is only minimized by scrolling is left to SwiftUI.
    func revealsTabBar(_ token: Int, when active: Bool = true) -> some View {
        background(TabBarRevealer(token: token, active: active).frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

private struct TabBarRevealer: UIViewRepresentable {
    let token: Int
    let active: Bool

    final class Coordinator {
        var token: Int?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context _: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        guard active, context.coordinator.token != token else { return }
        context.coordinator.token = token
        // On the next turn, once this update has landed and the view sits in the tab's controller chain.
        Task { @MainActor [weak view] in
            guard let view, let tabs = Self.tabBarController(of: view), tabs.isTabBarHidden else { return }
            tabs.setTabBarHidden(false, animated: true)
        }
    }

    /// The tab bar controller SwiftUI's TabView runs on, found up the responder chain from a view inside a tab.
    static func tabBarController(of view: UIView) -> UITabBarController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let controller = current as? UIViewController, let tabs = controller.tabBarController ?? (controller as? UITabBarController) {
                return tabs
            }
            responder = current.next
        }
        return nil
    }
}
