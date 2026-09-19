import SwiftUI

/// Library · Import · Settings, over the ink background, with a launch overlay and a recovery screen.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showLaunchOverlay = false

    var body: some View {
        @Bindable var model = model
        ZStack {
            switch model.phase {
            case .ready, .launching:
                TabView(selection: $model.selectedTab) {
                    Tab("Library", systemImage: "books.vertical", value: .library) { LibraryView() }
                    Tab("Import", systemImage: "square.and.arrow.down", value: .importGames) { ImportView() }
                    Tab("Settings", systemImage: "slider.horizontal.3", value: .settings) { SettingsView() }
                }
                .disabled(model.phase == .launching)
            case let .storeFailed(message):
                RecoveryView(message: message)
            }
            if model.phase == .launching, showLaunchOverlay {
                LaunchOverlay()
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            showLaunchOverlay = true
        }
    }
}

private struct LaunchOverlay: View {
    var body: some View {
        ZStack {
            InkBackground()
            VStack(spacing: Theme.s4) {
                Text("OmniPlay").font(Theme.title(34)).foregroundStyle(Theme.textPrimary)
                ProgressView().tint(Theme.lantern)
                Text("Opening your library").font(.footnote).foregroundStyle(Theme.textSecondary)
            }
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Opening your library")
    }
}

/// Shown when the library database cannot be opened. Game files are never touched by the reset.
struct RecoveryView: View {
    @Environment(AppModel.self) private var model
    let message: String
    @State private var bundleURL: URL?
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            Spacer()
            Text("The library could not be opened").font(Theme.title(26)).foregroundStyle(Theme.textPrimary)
            Text(
                "Your game files are safe. You can export a diagnostics bundle for the log, "
                    + "or reset the library database and import the games again."
            )
            .foregroundStyle(Theme.textSecondary)
            Text(message).font(.system(.footnote, design: .monospaced)).foregroundStyle(Theme.textSecondary).lineLimit(6)
                .padding(Theme.s3).glassCard(radius: 12)
            HStack(spacing: Theme.s3) {
                if let bundleURL {
                    ShareLink(item: bundleURL) { Label("Share diagnostics", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.bordered)
                } else {
                    Button("Export diagnostics") { Task { bundleURL = try? await HostSession.shared.exportBundle() } }
                        .buttonStyle(.bordered)
                }
                Button("Reset library database") { confirmReset = true }.buttonStyle(LanternButtonStyle())
            }
            Spacer()
        }
        .padding(Theme.s6)
        .frame(maxWidth: 560)
        .background(InkBackground())
        .confirmationDialog("Reset the library database?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset database, keep game files", role: .destructive) { Task { await model.resetLibraryDatabase() } }
        } message: {
            Text("Library entries, detection results and settings are removed. Files under Games remain on disk.")
        }
    }
}
