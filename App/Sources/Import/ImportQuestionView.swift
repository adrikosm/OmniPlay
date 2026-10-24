import GameCore
import GameImport
import GameStore
import SwiftUI

/// The question a paused import asks, answered in its row: the same file again, the same game in other files (with
/// both releases side by side), or which of several folders is the game. The recommended answer is the white pill.
struct ImportQuestionView: View {
    @Environment(AppModel.self) private var model
    let question: ImportQuestion
    let fileName: String
    let answer: (ImportAnswer) -> Void
    @State private var game: GameRecord?
    @State private var saves = 0
    @State private var mods = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            switch question {
            case let .sameFile(existing, title):
                prompt("You already have \(title), from the same file.")
                choices([
                    ("Cancel", .cancel, .primary),
                    ("Overwrite", .replace(existing), .secondary),
                    ("Keep both", .keepBoth, .secondary),
                ])
                note("Overwrite reinstalls the game. Saves, play time and your cover stay.")
            case let .otherVersion(existing, title, installed, incoming, order, bytes):
                prompt(Self.message(title: title, installed: installed, incoming: incoming, order: order))
                comparison(installed: installed, incoming: incoming, bytes: bytes)
                if order == .newer || order == .unknown {
                    choices([("Update", .replace(existing), .primary), ("Keep both", .keepBoth, .secondary), ("Cancel", .cancel, nil)])
                } else {
                    choices([
                        ("Cancel", .cancel, .primary),
                        ("Overwrite", .replace(existing), .secondary),
                        ("Keep both", .keepBoth, .secondary),
                    ])
                }
                note(mods == 0 ? "Saves, play time and your cover stay." :
                    "Saves, play time, your cover and \(mods) mod\(mods == 1 ? "" : "s") stay.")
            case let .severalRoots(candidates):
                prompt("Several game folders are inside. Which one is the game?")
                ForEach(candidates.sorted(), id: \.self) { candidate in
                    Button { answer(.root(candidate)) } label: {
                        Label(candidate, systemImage: "folder").font(Theme.mono).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.link)
                }
                Button("Cancel") { answer(.cancel) }.buttonStyle(.link)
            }
        }
        .rise(0)
        .sensoryFeedback(.warning, trigger: question)
        .task(id: question) {
            guard case let .otherVersion(existing, _, _, _, _, _) = question, let store = model.store else { return }
            game = try? store.games.fetch(id: existing)
            saves = (try? store.saves.fetch(game: existing).count) ?? 0
            mods = (try? store.mods.fetch(game: existing).count) ?? 0
        }
    }

    static func message(title: String, installed: String?, incoming: String?, order: VersionOrder) -> String {
        switch (order, installed, incoming) {
        case let (.newer, old?, new?): "Update \(title) from \(old) to \(new)?"
        case let (.older, old?, new?): "This is \(new). You have \(old)."
        case (.same, _, _): "Same version of \(title), from a different file."
        default: "Another version of \(title)."
        }
    }

    private func prompt(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
    }

    /// One row of answers that stacks when it does not fit; a nil style is a text link.
    private func choices(_ items: [(String, ImportAnswer, PillButtonStyle?)]) -> some View {
        let row = ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            let (title, value, style) = item
            if let style {
                Button(title) { answer(value) }.buttonStyle(style)
            } else {
                Button(title) { answer(value) }.buttonStyle(.link).frame(minHeight: 44)
            }
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.s3) { row }
            VStack(alignment: .leading, spacing: Theme.s2) { row }
        }
    }

    /// The game in the library beside the file being imported.
    private func comparison(installed: String?, incoming: String?, bytes: Int64) -> some View {
        let library = VStack(alignment: .leading, spacing: Theme.s2) {
            Text("In your library").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            HStack(spacing: Theme.s3) {
                if let game {
                    CoverImage(path: game.artworkPath, engine: game.engine, maxPixels: 120)
                        .frame(width: 30, height: 40)
                        .clipShape(.rect(cornerRadius: 6, style: .continuous))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text([installed ?? "Version unknown", game.map { Self.size($0.installBytes) }].compactMap(\.self).joined(separator: " · "))
                        .font(Theme.mono).foregroundStyle(Theme.textPrimary)
                    Group {
                        if let played = game?.lastPlayedAt {
                            Text("Played \(played, format: .relative(presentation: .named)) · \(saves) save\(saves == 1 ? "" : "s")")
                        } else {
                            Text("Not played yet · \(saves) save\(saves == 1 ? "" : "s")")
                        }
                    }
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        let file = VStack(alignment: .leading, spacing: Theme.s2) {
            Text("This file").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            Text("\(incoming ?? "Version unknown") · \(Self.size(bytes))").font(Theme.mono).foregroundStyle(Theme.textPrimary)
            Text(fileName).font(Theme.mono).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
        }
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Theme.s2) {
                tile(library)
                tile(file)
            }
            VStack(spacing: Theme.s2) {
                tile(library)
                tile(file)
            }
        }
    }

    private func tile(_ content: some View) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.s3)
            .background(Theme.fill, in: .rect(cornerRadius: Theme.fieldRadius, style: .continuous))
            .accessibilityElement(children: .combine)
    }

    private static func size(_ bytes: Int64) -> String { bytes.formatted(.byteCount(style: .file)) }
}
