import SwiftUI

/// Top-level shell: Library · Import · Diagnostics · Settings (design authority §4).
struct RootView: View {
    var body: some View {
        TabView {
            Tab("Library", systemImage: "gamecontroller") {
                LibraryView()
            }
            Tab("Import", systemImage: "square.and.arrow.down") {
                ImportView()
            }
            Tab("Diagnostics", systemImage: "waveform.path.ecg") {
                DiagnosticsView()
            }
            Tab("Settings", systemImage: "gear") {
                SettingsView()
            }
        }
    }
}

#Preview {
    RootView()
}
