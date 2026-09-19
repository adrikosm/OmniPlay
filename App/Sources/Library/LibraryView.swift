import GameCore
import GameStore
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [GameRecord] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let store = model.store {
                    LibraryContent(viewModel: LibraryViewModel(store: store, paths: model.paths), path: $path)
                } else {
                    Color.clear
                }
            }
            .inkScreen()
            .navigationTitle("Library")
            .navigationDestination(for: GameRecord.self) { GameDetailView(game: $0) }
        }
    }
}

private struct LibraryContent: View {
    @Environment(AppModel.self) private var model
    @State var viewModel: LibraryViewModel
    @Binding var path: [GameRecord]
    @State private var pendingDelete: GameRecord?

    private let columns = [GridItem(.adaptive(minimum: 108, maximum: 160), spacing: Theme.s3)]

    var body: some View {
        ScrollView {
            if viewModel.games.isEmpty, viewModel.query.isEmpty {
                EmptyLibrary { model.selectedTab = .importGames }
            } else if viewModel.games.isEmpty {
                ContentUnavailableView.search(text: viewModel.query).padding(.top, Theme.s8)
            } else {
                LazyVGrid(columns: columns, spacing: Theme.s4) {
                    ForEach(viewModel.games) { game in
                        NavigationLink(value: game) { GameTile(game: game) }
                            .buttonStyle(TileButtonStyle())
                            .contextMenu {
                                Button("Delete game", systemImage: "trash", role: .destructive) { pendingDelete = game }
                            }
                    }
                }
                .padding(.horizontal, Theme.s4)
                .padding(.bottom, Theme.s8)
            }
            if let error = viewModel.error {
                Text(error).font(.footnote).foregroundStyle(Theme.danger).padding()
            }
        }
        .searchable(text: $viewModel.query, prompt: "Search titles")
        #if DEBUG
            .onChange(of: viewModel.games.isEmpty) { _, empty in
                if !empty, DebugLaunch.openFirstGame, path.isEmpty, let first = viewModel.games.first {
                    path = [first]
                }
            }
        #endif
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $viewModel.sort) {
                            Text("Recently added").tag(LibrarySort.recentlyImported)
                            Text("Recently played").tag(LibrarySort.recentlyPlayed)
                            Text("Title").tag(LibrarySort.title)
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
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
    }
}

/// Cover tile: 3:4 art, serif title, engine and state chips. The whole tile is the target.
struct GameTile: View {
    let game: GameRecord

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            CoverImage(path: game.artworkPath, engine: game.engine)
                .aspectRatio(Theme.coverAspect, contentMode: .fit)
                .clipShape(.rect(cornerRadius: Theme.tileRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.tileRadius).strokeBorder(Theme.hairline, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if game.compatibilityState != .loadable {
                        Chip(text: game.compatibilityState.label, tint: game.compatibilityState.tint).padding(Theme.s2)
                    }
                }
            Text(game.title)
                .font(Theme.tileTitle)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            Text(game.engine.displayName)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(game.title), \(game.engine.displayName), \(game.compatibilityState.label)")
    }
}

/// Press feedback without moving layout bounds: a dim, not a scale.
struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(Theme.quick, value: configuration.isPressed)
    }
}

/// The first screen a new user sees: one invitation, no decoration competing with it.
struct EmptyLibrary: View {
    let importAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            Text("Your shelf is empty")
                .font(Theme.title(30))
                .foregroundStyle(Theme.textPrimary)
            Text(
                "Bring in a game from Files, a folder or a zip, and OmniPlay works out which engine it needs "
                    + "and keeps saves, mods and settings in one place."
            )
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: 420, alignment: .leading)
            Button(action: importAction) { Label("Import a game", systemImage: "square.and.arrow.down") }
                .buttonStyle(LanternButtonStyle())
                .padding(.top, Theme.s2)
        }
        .padding(Theme.s6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Theme.s8)
    }
}
