import Diagnostics
import UIKit

/// Process-level hooks that SwiftUI does not expose: launch logging now; KSCrash installation,
/// `GameController` discovery and memory-pressure sources in later phases.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        DiagnosticsLog.logger(.runtime).info("OmniPlay launched (UIScene lifecycle)")
        return true
    }
}
