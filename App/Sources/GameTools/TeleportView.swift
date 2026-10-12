import GameStore
import GameTools
import RuntimeCore
import SwiftUI

/// Where the player stands, spots saved to come back to, and every map of the game to jump to. A jump to another map is
/// the game's own transfer, so it happens as the game resumes.
struct TeleportView: View {
    let tools: MutationEngine
    let game: GameRecord
    @State private var here: Spot?
    @State private var maps: [MapName] = []
    @State private var spots: [Spot] = []
    @State private var query = ""
    @State private var chosen: MapName?
    @State private var x = ""
    @State private var y = ""
    @State private var note: String?
    @State private var failed = false
    @State private var working = false
    @State private var outcome = 0

    struct Spot: Codable, Hashable, Identifiable {
        var name: String
        var map: Int
        var x: Int
        var y: Int
        var id: String { "\(map).\(x).\(y)" }
    }

    struct MapName: Hashable, Identifiable {
        let id: Int
        let name: String
    }

    private var spotsKey: String { "cheats.spots.\(game.id.rawValue.uuidString)" }

    private var shownMaps: [MapName] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? maps : maps.filter { $0.name.lowercased().contains(q) || String($0.id) == q }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s4) {
                if let note {
                    Text(note).font(.footnote).foregroundStyle(failed ? Theme.danger : Theme.textSecondary)
                        .padding(.horizontal, Theme.s4)
                        .transition(.opacity)
                }
                GlassSection("Where you are") {
                    ListRow(
                        icon: "location",
                        title: here.map { mapName($0.map) } ?? "Reading…",
                        subtitle: here.map { "Tile \($0.x), \($0.y)" }
                    ) {
                        Button("Save spot") { saveHere() }
                            .buttonStyle(PillButtonStyle(kind: .secondary, height: 34))
                            .frame(minHeight: 44)
                            .disabled(here == nil)
                    }
                }
                .rise(0)
                GlassSection(
                    "Saved spots",
                    footer: spots.isEmpty ? nil : "Touch and hold a spot to remove it. Spots stay with this game."
                ) {
                    if spots.isEmpty {
                        Text("Save a spot before a boss or a long walk, then come back to it in one tap.")
                            .font(.footnote).foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.s4)
                    }
                    ForEach(spots) { spot in
                        ListRow(icon: "mappin", title: spot.name, subtitle: "\(mapName(spot.map)), tile \(spot.x), \(spot.y)") {
                            goButton { await go(map: spot.map, x: spot.x, y: spot.y) }
                        }
                        .contextMenu {
                            Button("Remove", systemImage: "trash", role: .destructive) { remove(spot) }
                        }
                    }
                }
                .rise(1)
                GlassSection(
                    "Go to a map",
                    footer: "You land on the tile you choose. If it is inside a wall, turn on Walk through walls first."
                ) {
                    SearchField(text: $query, prompt: "Map name or number")
                        .padding(Theme.s3)
                    ForEach(shownMaps.prefix(80)) { map in
                        mapRow(map)
                    }
                    if maps.isEmpty {
                        Text("Reading the game's maps…").font(.footnote).foregroundStyle(Theme.textSecondary).padding(Theme.s4)
                    }
                }
                .rise(2)
            }
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s3)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .canvas()
        .navigationTitle("Teleport")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: outcome)
        .animation(Theme.quick, value: note)
        .task {
            spots = (UserDefaults.standard.data(forKey: spotsKey)).flatMap { try? JSONDecoder().decode([Spot].self, from: $0) } ?? []
            await readHere()
            await readMaps()
        }
    }

    /// A map; chosen, it opens to the tile to land on, which starts at the player's own tile.
    @ViewBuilder private func mapRow(_ map: MapName) -> some View {
        let open = chosen == map
        VStack(spacing: 0) {
            Button {
                withAnimation(Theme.snap) {
                    chosen = open ? nil : map
                    x = here.map { String($0.x) } ?? "0"
                    y = here.map { String($0.y) } ?? "0"
                }
            } label: {
                ListRow(icon: "map", title: map.name, subtitle: "Map \(map.id)") {
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                }
            }
            .buttonStyle(.row)
            if open {
                HStack(spacing: Theme.s2) {
                    coordinate("X", text: $x)
                    coordinate("Y", text: $y)
                    Spacer(minLength: 0)
                    goButton {
                        guard let tx = Int(x), let ty = Int(y) else {
                            failed = true
                            note = "Type whole numbers for the tile."
                            return
                        }
                        await go(map: map.id, x: tx, y: ty)
                    }
                }
                .padding(.horizontal, Theme.s4)
                .padding(.bottom, Theme.s3)
                .transition(.opacity)
            }
        }
    }

    private func coordinate(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: Theme.s1) {
            Text(label).font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            TextField(label, text: text)
                .keyboardType(.numberPad)
                .font(Theme.value)
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 56)
        }
        .padding(.horizontal, Theme.s3)
        .frame(minHeight: 44)
        .background(Theme.fill, in: .rect(cornerRadius: Theme.fieldRadius, style: .continuous))
    }

    private func goButton(_ action: @escaping () async -> Void) -> some View {
        Button("Go") { Task { await action() } }
            .buttonStyle(PillButtonStyle(kind: .primary, height: 34))
            .frame(minHeight: 44)
            .disabled(working)
    }

    private func mapName(_ id: Int) -> String {
        maps.first { $0.id == id }?.name ?? "Map \(id)"
    }

    private func go(map: Int, x: Int, y: Int) async {
        working = true
        defer { working = false }
        let sameMap = map == here?.map
        let result = await tools.apply(
            .setValue(.dict(["map": .int(map), "x": .int(x), "y": .int(y)])),
            to: .playerPosition
        )
        if result.result == .rejected {
            failed = true
            note = result.validation.first?.message ?? "The game refused the teleport."
            return
        }
        failed = false
        outcome += 1
        note = sameMap ? "Moved to tile \(x), \(y)." : "You'll arrive at \(mapName(map)) as soon as you go back to the game."
        if sameMap {
            await readHere()
        }
    }

    private func saveHere() {
        guard let here else { return }
        var spot = here
        spot.name = mapName(here.map)
        spots.removeAll { $0.id == spot.id }
        spots.insert(spot, at: 0)
        store()
        outcome += 1
    }

    private func remove(_ spot: Spot) {
        spots.removeAll { $0.id == spot.id }
        store()
    }

    private func store() {
        UserDefaults.standard.set(try? JSONEncoder().encode(spots), forKey: spotsKey)
    }

    private func readHere() async {
        guard case let .dict(position)? = try? await tools.read(.playerPosition),
              case let .int(map)? = position["map"], case let .int(x)? = position["x"], case let .int(y)? = position["y"]
        else {
            failed = true
            note = "The player's position is not available yet. Resume the game, then come back."
            return
        }
        here = Spot(name: "", map: map, x: x, y: y)
    }

    private func readMaps() async {
        var all: [MapName] = []
        var page = StatePage(size: 1000)
        while let result = try? await tools.list(.maps, query: nil, page: page) {
            for entry in result.entries {
                if case let .map(id) = entry.target {
                    all.append(MapName(id: id, name: entry.name))
                }
            }
            guard result.hasMore else { break }
            page = page.next
        }
        maps = all
    }
}
