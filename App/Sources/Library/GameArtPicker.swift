import GameCore
import GameStore
import SwiftUI

/// "Choose from the game": every picture the game's own files offer, each shown filled into the cover shape (an
/// icon as the composed cover it would become). Tapping one opens the crop view.
struct GameArtPicker: View {
    let game: GameRecord
    /// Called with the written cover's stored path.
    let onChosen: (String) async -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var tiles: [Tile] = []
    @State private var loading = true
    @State private var cropping: Tile?

    struct Tile: Identifiable, @unchecked Sendable {
        let id: String
        /// What the cover would be: the picture itself, or for an icon the composed cover.
        let image: CGImage
        let isIcon: Bool
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if !loading, tiles.isEmpty {
                    Text("No pictures found in this game's files. Use as cover in the pause menu takes one from the game itself.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.s4)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: Theme.s3)], spacing: Theme.s3) {
                        ForEach(tiles) { tile in
                            Button { cropping = tile } label: { cover(tile) }
                                .buttonStyle(PressButtonStyle())
                                .accessibilityLabel(tile.isIcon ? "Icon, \(Self.name(tile.id))" : Self.name(tile.id))
                                .accessibilityHint("Opens the crop view.")
                        }
                        if loading {
                            placeholder
                        }
                    }
                    .padding(Theme.s4)
                }
            }
            .canvas()
            .navigationTitle("Choose from the game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.buttonStyle(.link).fixedSize()
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
        .fullScreenCover(item: $cropping) { tile in
            CoverCropView(image: tile.image) { crop in
                let (id, paths) = (game.id, model.paths)
                if let path = await Task.detached(operation: { CoverExtractor.write(cgImage: crop, game: id, paths: paths) }).value {
                    await onChosen(path)
                    cropping = nil
                    dismiss()
                }
            } onCancel: { cropping = nil }
        }
    }

    private func cover(_ tile: Tile) -> some View {
        Color.clear
            .aspectRatio(Theme.coverAspect, contentMode: .fit)
            .overlay(Image(decorative: tile.image, scale: 1).resizable().scaledToFill())
            .clipShape(.rect(cornerRadius: Theme.coverRadius, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                if tile.isIcon {
                    Text("Icon").font(.caption2.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, Theme.s2).padding(.vertical, 3)
                        .background(Theme.canvas.opacity(0.7), in: .capsule)
                        .padding(Theme.s2)
                }
            }
            .coverEdge(radius: Theme.coverRadius)
    }

    /// Keeps the grid from jumping while the next picture decodes.
    private var placeholder: some View {
        RoundedRectangle(cornerRadius: Theme.coverRadius, style: .continuous)
            .fill(Theme.fill)
            .aspectRatio(Theme.coverAspect, contentMode: .fit)
            .overlay(ProgressView().tint(Theme.textSecondary))
            .accessibilityLabel("Looking for more pictures")
    }

    /// "Castle" from `www/img/titles1/Castle.rpgmvp`, "Game" from `Game.exe`.
    static func name(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    private func load() async {
        let (id, engine, root, paths) = (game.id, game.engine, game.rootRelPath, model.paths)
        let stream = AsyncStream<Tile> { continuation in
            Task.detached {
                _ = CoverExtractor.candidates(game: id, engine: engine, rootRelativePath: root, paths: paths) { candidate in
                    let image = candidate.isIcon ? CoverExtractor.compose(icon: candidate.image) : candidate.image
                    if let image {
                        continuation.yield(Tile(id: candidate.id, image: image, isIcon: candidate.isIcon))
                    }
                }
                continuation.finish()
            }
        }
        for await tile in stream {
            tiles.append(tile)
        }
        loading = false
    }
}
