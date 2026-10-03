import SwiftUI

/// Library · Import · Settings in the floating glass tab bar, with search as its own round button beside it.
/// The startup mark plays over everything until the library is open, then lifts away.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var introPlayed = false
    @State private var introDone = false
    @State private var query = ""

    private var running: ImportItem? { model.imports?.items.first { !$0.state.isTerminal } }

    var body: some View {
        @Bindable var model = model
        ZStack {
            switch model.phase {
            case .ready, .launching:
                TabView(selection: $model.selectedTab) {
                    // The bar's selected tab is a light fill with white; the accent stays for links and Play inside.
                    Tab("Library", systemImage: "square.grid.2x2", value: .library) { LibraryView().tint(Theme.accent) }
                    Tab("Import", systemImage: "square.and.arrow.down", value: .importGames) { ImportView().tint(Theme.accent) }
                    Tab("Settings", systemImage: "slider.horizontal.3", value: .settings) { SettingsView().tint(Theme.accent) }
                    Tab(value: .search, role: .search) { LibrarySearchView(query: query).tint(Theme.accent) }
                }
                .tint(Theme.textPrimary)
                .tabBarMinimizeBehavior(.onScrollDown)
                // An import still running while the player is elsewhere; tapping it goes back to Import.
                .tabViewBottomAccessory(isEnabled: running != nil && model.selectedTab != .importGames) {
                    Button { model.selectedTab = .importGames } label: {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small).tint(Theme.textPrimary)
                            Text("Importing \(running?.name ?? "")").font(.subheadline).lineLimit(1)
                        }
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, Theme.s4)
                    }
                    .accessibilityHint("Opens Import")
                }
                .searchable(text: $query, prompt: "Titles in your library")
                .disabled(model.phase == .launching)
            case let .storeFailed(message):
                RecoveryView(message: message)
            }
            if !introDone {
                StartupView { introPlayed = true }
                    .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 1.04)))
                    .zIndex(1)
            }
        }
        // The mark lifts away once it has assembled and the library is open, whichever comes last.
        .onChange(of: introPlayed && model.phase != .launching) { _, done in
            if done {
                withAnimation(Theme.motion(.easeOut(duration: 0.45), reduce: reduceMotion)) { introDone = true }
            }
        }
        .alert(
            "A game closed unexpectedly",
            isPresented: Binding(get: { !model.unexpectedEnds.isEmpty && introDone }, set: {
                if !$0 {
                    model.unexpectedEnds = []
                }
            })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                "OmniPlay stopped while \(ListFormatter.localizedString(byJoining: model.unexpectedEnds)) was running. "
                    + "Saves and backups has a copy of any saves from before that session, and its log is under Diagnostics."
            )
        }
    }
}

/// The app icon assembling itself: the three dots pop in one by one, the arrow slides home, the name rises and a
/// quiet spinner says what is happening. Reports when the mark is whole; RootView lifts it once the library is open too.
private struct StartupView: View {
    let played: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var assembled = false

    var body: some View {
        ZStack {
            CanvasBackground()
            VStack(spacing: 20) {
                RoundedRectangle(cornerRadius: 20.6, style: .continuous)
                    .fill(Theme.textPrimary)
                    .frame(width: 92, height: 92)
                    .overlay(OmniMark(size: 57, color: Theme.canvas, assembled: assembled))
                Text("OmniPlay").display(26, weight: .semibold).maskedRise(delay: 0.5)
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(Theme.textPrimary)
                    Text("Opening your library").font(.subheadline).foregroundStyle(Theme.textSecondary)
                }
                .rise(9)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("OmniPlay. Opening your library")
        .task {
            assembled = true
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 300 : 1300))
            played()
        }
    }
}

/// Shown when the library database cannot be opened. Calm and direct: what happened, the error, then three actions
/// in order of safety. Game files are never touched by the reset.
struct RecoveryView: View {
    @Environment(AppModel.self) private var model
    let message: String
    @State private var bundleURL: URL?
    @State private var exporting = false
    @State private var confirmReset = false

    var body: some View {
        Split(leadingWidth: 400) {
            VStack(alignment: .leading, spacing: Theme.s4) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Your library").display(40).maskedRise(0)
                    Text("didn't open").display(40).maskedRise(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Text("Your games and saves are still on this iPhone. Export diagnostics first so the log is kept, then try again.")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .rise(2)
                Text(message)
                    .font(Theme.mono).foregroundStyle(Theme.textSecondary)
                    .lineLimit(4).textSelection(.enabled)
                    .padding(.horizontal, Theme.s3).padding(.vertical, Theme.s2)
                    .background(Theme.fill, in: .rect(cornerRadius: Theme.fieldRadius, style: .continuous))
                    .rise(3)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        } trailing: {
            VStack(spacing: Theme.s3) {
                Button { Task { await model.launch() } } label: { Text("Try again").frame(maxWidth: .infinity) }
                    .buttonStyle(.primary)
                if let bundleURL {
                    ShareLink(item: bundleURL) { Label("Share diagnostics", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                        .buttonStyle(.secondary)
                } else {
                    Button {
                        exporting = true
                        Task {
                            bundleURL = try? await HostSession.shared.exportBundle()
                            exporting = false
                        }
                    } label: { Text(exporting ? "Exporting…" : "Export diagnostics").frame(maxWidth: .infinity) }
                        .buttonStyle(.secondary)
                        .disabled(exporting)
                }
                Button(role: .destructive) { confirmReset = true } label: { Text("Reset library…").frame(maxWidth: .infinity) }
                    .buttonStyle(.destructive)
                Text("You'll be asked to confirm before anything is removed.")
                    .font(.footnote).foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.s1)
            }
            .rise(4)
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .padding(.horizontal, Theme.s6)
        .padding(.vertical, Theme.s6)
        .frame(maxHeight: .infinity)
        .background(CanvasBackground())
        .confirmationDialog("Reset the library database?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset database, keep game files", role: .destructive) { Task { await model.resetLibraryDatabase() } }
        } message: {
            Text("Library entries, detection results and settings are removed. Files under Games remain on disk.")
        }
    }
}

/// The reference layout: two columns in landscape (and on iPad), stacked in portrait and at accessibility sizes.
struct Split<Leading: View, Trailing: View>: View {
    var spacing: CGFloat = 30
    var leadingWidth: CGFloat?
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @Wide private var wide

    var body: some View {
        if wide {
            HStack(alignment: .top, spacing: spacing) {
                if let leadingWidth {
                    leading.frame(width: leadingWidth, alignment: .topLeading)
                } else {
                    leading.frame(maxWidth: .infinity, alignment: .topLeading)
                }
                trailing.frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.s6) {
                leading
                trailing
            }
        }
    }
}

/// Landscape iPhone or any iPad width, and not at an accessibility text size.
@propertyWrapper struct Wide: DynamicProperty {
    @Environment(\.verticalSizeClass) private var vertical
    @Environment(\.horizontalSizeClass) private var horizontal
    @Environment(\.dynamicTypeSize) private var type
    var wrappedValue: Bool { (vertical == .compact || horizontal == .regular) && !type.isAccessibilitySize }
}
