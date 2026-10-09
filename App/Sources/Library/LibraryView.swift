import GameCore
import GameStore
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
/// Portrait stacks the featured game over the covers in a three-column grid. Favourites and Hidden are this screen, filtered.
struct LibraryContent: View {
    @Environment(AppModel.self) var model
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.scenePhase) var scenePhase
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

    @Wide var wide
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
                            grid
                        } else {
                            emptyState
                        }
                    }
                    .padding(.top, Theme.s3)
                    .padding(.bottom, 96)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .padding(.horizontal, Theme.s4)
        .canvas()
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
                guard let id else { return }
                if let target = viewModel.games.first(where: { $0.id == id }) {
                    path = [target]
                    model.clearPendingOpen()
                } else if viewModel.filter != .all {
                    // A filtered shelf may not hold the game: show All, and the games onChange below opens it.
                    viewModel.filter = .all
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
            // The hidden shelf locks again once the app goes to the background (not on .inactive: the passcode sheet
            // itself makes the scene inactive), so the next look asks again.
            .onChange(of: scenePhase) { _, phase in
                if phase == .background, viewModel.filter == .hidden {
                    viewModel.filter = .all
                }
            }
            .confirmationDialog(
                "Delete \(pendingDelete?.title ?? "this game")?", isPresented: $pendingDelete.isPresent(),
                titleVisibility: .visible, presenting: pendingDelete
            ) { game in
                ForEach([true, false], id: \.self) { keepSaves in
                    Button(keepSaves ? "Delete game, keep saves" : "Delete game and all its data", role: .destructive) {
                        Task { await viewModel.delete(game, keepSaves: keepSaves) }
                    }
                }
            } message: { _ in
                Text(GameDeletion.explanation)
            }
            .alert("New collection", isPresented: $naming) {
                TextField("Name", text: $newName)
                Button("Create") { viewModel.createCollection(named: newName, with: adding) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(adding.map { "\"\($0.title)\" goes in it." } ?? "Add games from their cover's menu.")
            }
    }
}
