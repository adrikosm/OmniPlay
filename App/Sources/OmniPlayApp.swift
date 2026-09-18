import Diagnostics
import SwiftUI

/// OmniPlay host application.
///
/// SwiftUI's `App` lifecycle is UIScene-based, which the iOS 27 SDK requires (design authority §2.4).
/// The shell owns `UIApplication`; every engine (WKWebView, SDL-based, Godot) renders into a view
/// the shell provides. Nothing in `Packages/` imports SwiftUI.
@main
struct OmniPlayApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
