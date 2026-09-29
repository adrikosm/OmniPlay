import GameCore
import GameStore
import LocalAuthentication
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) var model
    @State var path: [GameRecord] = []
    /// Set by Continue: the game page it opens starts playing straight away.
    @State var autoplay: GameID?
    @Namespace var zoom

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let store = model.store {
                    LibraryContent(
                        viewModel: LibraryViewModel(store: store, paths: model.paths),
                        path: $path,
                        autoplay: $autoplay,
                        zoom: zoom
                    )
                } else {
                    Color.clear.canvas()
                }
            }
            .toolbarVisibility(.hidden, for: .navigationBar)
            .navigationDestination(for: GameRecord.self) {
                // The cover grows into the page, and the page shrinks back into it.
                GameDetailView(game: $0, autoplay: $0.id == autoplay).navigationTransition(.zoom(sourceID: $0.id, in: zoom))
            }
            .onChange(of: path) { _, path in
                if path.isEmpty {
                    autoplay = nil
                }
            }
        }
    }
}

/// Landscape: the featured game on the left (its title rolls when the shelf moves), the shelf of covers on the right.
/// The cover at the shelf's leading edge is the featured one, marked by a thin accent line; Continue plays it.
/// Portrait stacks the same parts. Favourites and Hidden are this screen, filtered.
struct LibraryContent: View {
    @Environment(AppModel.self) var model
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.verticalSizeClass) var verticalSizeClass
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.dynamicTypeSize) var typeSize
    @State var viewModel: LibraryViewModel
    @Binding var path: [GameRecord]
    @Binding var autoplay: GameID?
    let zoom: Namespace.ID
    @State var featuredID: GameID?
    /// Which way the featured title rolls: forward along the shelf rises from below.
    @State var forward = true
    @State var shelfWidth: CGFloat = 500
    @State var pendingDelete: GameRecord?
    /// Naming a new collection; `adding` is the game it starts with, if it came from a cover's menu.
    @State var naming = false
    @State var adding: GameRecord?
    @State var newName = ""
    @State var shelfError: String?
    @Namespace var marker
    /// Bumped to bring back a tab bar left hidden (`revealsTabBar`); `contentBottom` places the tap band above it.
    @State var tabBarToken = 0
    @State var contentBottom: CGFloat = 0

    var wide: Bool { Adaptive.wide(vertical: verticalSizeClass, horizontal: horizontalSizeClass, type: typeSize) }
    var featured: GameRecord? { viewModel.games.first { $0.id == featuredID } ?? viewModel.games.first }

    var body: some View {
        Group {
            if wide {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if let featured {
                        HStack(alignment: .top, spacing: 30) {
                            featuredColumn(featured).frame(width: 300, alignment: .leading)
                            shelf
                        }
                    } else {
                        emptyState
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, Theme.s3)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.s6) {
                        header
                        if let featured {
                            featuredColumn(featured)
                            shelf
                        } else {
                            emptyState
                        }
                    }
                    .padding(.top, Theme.s3)
                    .padding(.bottom, 96)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting {
                        showTabBar()
                    }
                }
            }
        }
        .padding(.horizontal, Theme.s4)
        .canvas()
        // The tab bar belongs on the library. Scrolling, or a tap where the bar sits, brings it back if a game's page
        // left it hidden; so does coming back to the shelf.
        .toolbarVisibility(.visible, for: .tabBar)
        .revealsTabBar(tabBarToken, when: path.isEmpty)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { contentBottom = $0 }
        .simultaneousGesture(SpatialTapGesture(coordinateSpace: .global).onEnded { tap in
            if tap.location.y > contentBottom - 90 {
                showTabBar()
            }
        })
        .onAppear { showTabBar() }
        .onChange(of: path.isEmpty) { _, root in
            guard root else { return }
            Task {
                // After the page has zoomed back into its cover.
                try? await Task.sleep(for: .milliseconds(450))
                showTabBar()
            }
        }
        #if DEBUG
            .onChange(of: viewModel.games.isEmpty) { _, empty in
                if !empty, DebugLaunch.openFirstGame, path.isEmpty, let first = viewModel.games.max(by: { $0.importedAt < $1.importedAt }) {
                    Task {
                        await model.debugEditSave(first)
                        await model.debugMods(first)
                        // Opened once: a second push while the game plays takes its view off screen.
                        if path.isEmpty {
                            path = [first]
                        }
                    }
                }
            }
        #endif
            .onChange(of: model.pendingOpen) { _, id in
                if let id, let target = viewModel.games.first(where: { $0.id == id }) {
                    path = [target]
                    model.clearPendingOpen()
                }
            }
            .onChange(of: viewModel.games.map(\.id), initial: true) { _, ids in
                if let id = model.pendingOpen, let target = viewModel.games.first(where: { $0.id == id }) {
                    path = [target]
                    model.clearPendingOpen()
                }
                // First load, or the featured game left this filter: feature the one last played.
                if featuredID.map(ids.contains) != true {
                    featuredID = recent?.id ?? ids.first
                }
            }
            .confirmationDialog(
                "Delete \(pendingDelete?.title ?? "this game")?", isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: {
                        if !$0 {
                            pendingDelete = nil
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete game, keep saves", role: .destructive) {
                    if let game = pendingDelete {
                        Task { await viewModel.delete(game) }
                    }
                    pendingDelete = nil
                }
            } message: {
                Text("The game files are removed. Saves are kept and come back if you import the same game again.")
            }
            .alert("New collection", isPresented: $naming) {
                TextField("Name", text: $newName)
                Button("Create") { viewModel.createCollection(named: newName, with: adding) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(adding.map { "\"\($0.title)\" goes in it." } ?? "Add games from their cover's menu.")
            }
    }

    func showTabBar() { tabBarToken &+= 1 }
}
