import GameCore
import GameStore
import LocalAuthentication
import SwiftUI

/// One cover on the shelf: 130 × 172 art, title and engine under it. The featured cover carries the accent line.
struct ShelfCover: View {
    let game: GameRecord
    var featured = false
    var restartNeeded = false
    var zoom: Namespace.ID?
    var marker: Namespace.ID?
    var width: CGFloat = 130

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            CoverImage(path: game.artworkPath, engine: game.engine, maxPixels: 400, title: game.title)
                .frame(width: width, height: width / Theme.coverAspect)
                .coverEdge()
                .zoomSource(game.id, in: zoom)
                .overlay(alignment: .bottom) {
                    if featured, let marker {
                        Capsule().fill(Theme.accent).frame(height: 2).offset(y: 5)
                            .matchedGeometryEffect(id: "featured", in: marker)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(game.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(game.compatibilityState == .refused ? Theme.danger : Theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.top, 2)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(game.title), \(status)\(game.favorite ? ", Favourite" : "")")
        .accessibilityAddTraits(featured ? .isSelected : [])
    }

    /// The engine, or the one state worth reading instead.
    private var status: String {
        if restartNeeded {
            return "Restart needed"
        }
        if game.compatibilityState != .playable, game.compatibilityState != .loadable {
            return game.compatibilityState.label
        }
        return game.engineName()
    }
}

/// The first screen a new user sees: one invitation, nothing competing with it.
struct EmptyLibrary: View {
    let importAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Your shelf").display(40).maskedRise(0)
                Text("is empty").display(40).maskedRise(1)
            }
            .accessibilityElement(children: .combine)
            Text(
                "Bring in a game from Files, a folder or a zip. OmniPlay works out which engine it needs "
                    + "and keeps saves, mods and settings in one place."
            )
            .font(.subheadline)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: 420, alignment: .leading)
            .rise(2)
            Button(action: importAction) { Label("Import a game", systemImage: "square.and.arrow.down") }
                .buttonStyle(.primary)
                .padding(.top, Theme.s2)
                .rise(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Theme.s4)
    }
}

/// The Search tab: the whole library, narrowed as you type, covers in a grid.
struct LibrarySearchView: View {
    let query: String
    @Environment(AppModel.self) private var model
    @State private var path: [GameRecord] = []
    @Namespace private var zoom

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let store = model.store {
                    SearchResults(viewModel: LibraryViewModel(store: store, paths: model.paths), query: query, zoom: zoom)
                } else {
                    Color.clear.canvas()
                }
            }
            .navigationTitle("Search")
            .navigationDestination(for: GameRecord.self) {
                GameDetailView(game: $0).navigationTransition(.zoom(sourceID: $0.id, in: zoom))
            }
        }
    }
}

struct SearchResults: View {
    @State var viewModel: LibraryViewModel
    let query: String
    let zoom: Namespace.ID

    var body: some View {
        ScrollView {
            if viewModel.games.isEmpty, !viewModel.query.isEmpty {
                ContentUnavailableView.search(text: viewModel.query).padding(.top, Theme.s8)
            } else if viewModel.games.isEmpty {
                Text("Games you import can be found here by title.")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    .padding(.top, Theme.s8)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 150), spacing: 18, alignment: .top)], spacing: Theme.s6) {
                ForEach(viewModel.games) { game in
                    NavigationLink(value: game) { ShelfCover(game: game, zoom: zoom) }
                        .buttonStyle(PressButtonStyle(scale: 0.96))
                }
            }
            .padding(Theme.s4)
            .padding(.bottom, 80)
        }
        .canvas()
        .onChange(of: query, initial: true) { _, text in viewModel.query = text }
    }
}

extension View {
    @ViewBuilder func zoomSource(_ id: GameID, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedTransitionSource(id: id, in: namespace) { $0.clipShape(.rect(cornerRadius: Theme.coverRadius, style: .continuous)) }
        } else {
            self
        }
    }
}
