import SwiftUI

/// OmniPlay host application. SwiftUI's `App` lifecycle is UIScene-based, which the iOS 27 SDK requires.
/// The shell owns `UIApplication`; every engine renders into a view the shell provides.
@main
struct OmniPlayApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.lantern)
                .task { await model.launch() }
                // "Open in OmniPlay" from Files or a share sheet: the file lands in the import queue.
                .onOpenURL { url in
                    model.selectedTab = .importGames
                    Task { await model.imports?.enqueue(url) }
                }
        }
    }
}
