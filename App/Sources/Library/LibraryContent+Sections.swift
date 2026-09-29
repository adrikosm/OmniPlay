import GameCore
import GameStore
import LocalAuthentication
import SwiftUI

extension LibraryContent {
    // MARK: Header

    var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.s3) {
                title
                Spacer(minLength: Theme.s4)
                filterBar
                if hasGames {
                    sortMenu
                }
            }
            VStack(alignment: .leading, spacing: Theme.s3) {
                HStack {
                    title
                    Spacer()
                    if hasGames {
                        sortMenu
                    }
                }
                filterBar
            }
        }
    }

    var title: some View {
        Text("Library").display(30).maskedRise().accessibilityAddTraits(.isHeader)
    }

    /// Anything in the library at all, in any filter.
    var hasGames: Bool { !(viewModel.games.isEmpty && viewModel.filter == .all) }

    @ViewBuilder var filterBar: some View {
        if hasGames {
            // The player's collections follow the fixed three, scrolling when they no longer fit.
            let collections = viewModel.collections.map { (LibraryFilter.collection($0.id), $0.name) }
            let counts = viewModel.collections.reduce(into: viewModel.counts) { $0[.collection($1.id)] = $1.games }
            ScrollView(.horizontal) {
                GlassSegmentBar(
                    items: [(LibraryFilter.all, "All"), (.favorites, "Favourites"), (.hidden, "Hidden")] + collections,
                    selection: Binding(get: { viewModel.filter }, set: { choose(filter: $0) }),
                    counts: counts
                )
                .fixedSize()
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .fixedSize(horizontal: collections.isEmpty, vertical: true)
            .rise(1)
        }
    }

    var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $viewModel.sort.animation(Theme.settle)) {
                Text("Recently added").tag(LibrarySort.recentlyImported)
                Text("Recently played").tag(LibrarySort.recentlyPlayed)
                Text("Title").tag(LibrarySort.title)
            }
            Section {
                Button("New collection", systemImage: "plus.rectangle.on.rectangle") { name(adding: nil) }
                if case let .collection(id) = viewModel.filter, let current = viewModel.collections.first(where: { $0.id == id }) {
                    Button("Delete \"\(current.name)\"", systemImage: "trash", role: .destructive) { viewModel.deleteCollection(id) }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 44, height: 44)
                .glass(Circle())
        }
        .tint(Theme.textPrimary)
        .accessibilityLabel("Sort")
        .rise(1)
    }

    // MARK: Featured

    func featuredColumn(_ game: GameRecord) -> some View {
        let animation = Theme.motion(Theme.roll, reduce: reduceMotion)
        let roll = AnyTransition.push(from: forward ? .bottom : .top)
        return VStack(alignment: .leading, spacing: 0) {
            Text(game.lastPlayedAt == nil ? "Start playing" : "Continue playing")
                .font(.footnote.weight(.medium)).foregroundStyle(Theme.textSecondary)
                .padding(.bottom, Theme.s3)
                .rise(2)
            ZStack(alignment: .topLeading) {
                Text(game.title)
                    .display(40)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(game.id)
                    .transition(reduceMotion ? .opacity : roll)
            }
            .maskedRise(1)
            ZStack(alignment: .topLeading) {
                Text(meta(game))
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(game.id)
                    .transition(reduceMotion ? .opacity : roll)
            }
            .clipped()
            .padding(.top, 6)
            .rise(3)
            HStack(spacing: 10) {
                Button { play(game) } label: {
                    Label(game.lastPlayedAt == nil ? "Play" : "Continue", systemImage: "play.fill")
                }
                .buttonStyle(.accent)
                Button { viewModel.setFavorite(game, !game.favorite) } label: {
                    Image(systemName: game.favorite ? "heart.fill" : "heart")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.round(48))
                .sensoryFeedback(.selection, trigger: game.favorite)
                .accessibilityLabel(game.favorite ? "Remove from favourites" : "Add to favourites")
            }
            .padding(.top, Theme.s6)
            .rise(4)
        }
        .animation(animation, value: game.id)
        .accessibilityElement(children: .contain)
    }

    func meta(_ game: GameRecord) -> String {
        let played = game.lastPlayedAt.map { "Played " + $0.formatted(.relative(presentation: .named)) } ?? "Not played yet"
        return "\(game.engineName()) · \(played)"
    }

    func play(_ game: GameRecord) {
        autoplay = game.id
        path = [game]
    }

    // MARK: Shelf

    var shelf: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 18) {
                ForEach(Array(viewModel.games.enumerated()), id: \.element.id) { index, game in
                    NavigationLink(value: game) {
                        ShelfCover(
                            game: game,
                            featured: game.id == featured?.id,
                            restartNeeded: restartNeeded(game),
                            zoom: zoom,
                            marker: marker
                        )
                    }
                    .buttonStyle(PressButtonStyle(scale: 0.96))
                    .contextMenu { menu(for: game).tint(Theme.textPrimary) }
                    .rise(3 + index, when: index < 6)
                }
                // Room after the last cover, so every game can reach the leading edge and be featured.
                Color.clear.frame(width: max(0, shelfWidth - 148), height: 1)
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: featuredBinding, anchor: .leading)
        .onScrollPhaseChange { _, phase in
            if phase == .interacting {
                showTabBar()
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { shelfWidth = $0 }
        .frame(height: 226)
        .overlay(alignment: .bottomLeading) { errorLine }
    }

    var featuredBinding: Binding<GameID?> {
        Binding(get: { featured?.id }, set: { new in
            guard let new, new != featured?.id else { return }
            let ids = viewModel.games.map(\.id)
            forward = (ids.firstIndex(of: new) ?? 0) >= (featured.flatMap { ids.firstIndex(of: $0.id) } ?? 0)
            withAnimation(Theme.motion(Theme.roll, reduce: reduceMotion)) { featuredID = new }
        })
    }

    @ViewBuilder func menu(for game: GameRecord) -> some View {
        Button(game.favorite ? "Remove from favourites" : "Add to favourites", systemImage: game.favorite ? "heart.slash" : "heart") {
            viewModel.setFavorite(game, !game.favorite)
        }
        Button(game.hidden ? "Show in library" : "Hide", systemImage: game.hidden ? "eye" : "eye.slash") {
            viewModel.setHidden(game, !game.hidden)
        }
        let memberships = viewModel.memberships(of: game)
        Menu("Collections", systemImage: "rectangle.stack") {
            ForEach(viewModel.collections) { collection in
                let member = memberships.contains(collection.id)
                Button(collection.name, systemImage: member ? "checkmark" : "rectangle") {
                    viewModel.setMember(game, of: collection.id, !member)
                }
            }
            Button("New collection", systemImage: "plus") { name(adding: game) }
        }
        Divider()
        Button("Delete game", systemImage: "trash", role: .destructive) { pendingDelete = game }
    }

    func name(adding game: GameRecord?) {
        adding = game
        newName = ""
        naming = true
    }

    @ViewBuilder var errorLine: some View {
        if let error = viewModel.error ?? shelfError {
            Text(error).font(.footnote).foregroundStyle(Theme.danger).padding(.vertical, Theme.s2)
        }
    }

    // MARK: Empty

    @ViewBuilder var emptyState: some View {
        if viewModel.filter == .all {
            EmptyLibrary { model.selectedTab = .importGames }
        } else {
            VStack(alignment: .leading, spacing: Theme.s3) {
                Text(emptyTitle).display(28).maskedRise()
                Text(viewModel.filter == .favorites
                    ? "Touch and hold a game on your shelf, or tap the heart beside Continue."
                    : viewModel.filter == .hidden ? "Games you hide from your shelf appear here."
                    : "Touch and hold a game on your shelf, then Collections.")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: 380, alignment: .leading)
                    .rise(1)
                Button("Show all games") { choose(filter: .all) }
                    .buttonStyle(.secondary)
                    .padding(.top, Theme.s2)
                    .rise(2)
                errorLine
            }
            .padding(.top, Theme.s4)
        }
    }

    var emptyTitle: String {
        switch viewModel.filter {
        case .favorites: "No favourites yet"
        case .hidden: "No hidden games"
        case let .collection(id): "Nothing in \(viewModel.collections.first { $0.id == id }?.name ?? "this collection") yet"
        default: "Nothing here"
        }
    }

    /// The last game actually played, shown first on the unfiltered shelf.
    var recent: GameRecord? {
        viewModel.games.filter { $0.lastPlayedAt != nil }.max { $0.lastPlayedAt! < $1.lastPlayedAt! }
    }

    func restartNeeded(_ game: GameRecord) -> Bool { game.runtime.map { model.spentSlots.contains($0.slot) } ?? false }

    /// The hidden shelf opens only after the device owner authenticates; the other filters switch at once.
    func choose(filter: LibraryFilter) {
        shelfError = nil
        guard filter == .hidden else { viewModel.filter = filter; return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            if (error as? LAError)?.code == .passcodeNotSet {
                // No passcode set: nothing to protect with, so the shelf simply opens.
                viewModel.filter = .hidden
            } else {
                shelfError = error?.localizedDescription ?? "The hidden shelf could not be unlocked. Try again."
            }
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Show the hidden shelf") { ok, failure in
            Task { @MainActor in
                if ok {
                    viewModel.filter = .hidden
                } else if let failure {
                    shelfError = failure.localizedDescription
                }
            }
        }
    }
}
