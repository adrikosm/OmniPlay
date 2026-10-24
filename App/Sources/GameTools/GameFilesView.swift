import GameCore
import GameImport
import GameStore
import OverlayVFS
import SwiftUI

/// Game Tools › Game files: the game's tree as the next launch reads it, merged across its own files, mods, files
/// OmniPlay prepared and the RTP, each tagged with where it comes from. Read-only: nothing here writes, so the sealed
/// original is never involved. With `pick`, it chooses a folder instead ("Use this folder").
struct GameFilesView: View {
    @Environment(AppModel.self) private var model
    let game: GameRecord
    /// The folder shown, as the game names it; "" is the game's root.
    var directory = ""
    var resolver: OverlayResolver?
    var pick: ((String) -> Void)?

    enum Scope: Hashable { case folder, game }

    @State private var loaded: OverlayResolver?
    @State private var entries: [Resolution] = []
    @State private var replaced: Set<String> = []
    @State private var failure: String?
    @State private var loading = true
    @State private var query = ""
    @State private var scope = Scope.folder
    @State private var results: [Resolution] = []
    @State private var resultsCut = false
    @State private var facts: String?
    @State private var zip = FolderZip()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s4) {
                if let facts, directory.isEmpty, pick == nil {
                    Text(facts).font(.subheadline).foregroundStyle(Theme.textSecondary).rise(0)
                }
                if pick == nil, !entries.isEmpty || !directory.isEmpty {
                    zipRow.rise(0)
                }
                GlassSection(footer: resultsCut && searching ? "Showing the first 500." : nil) {
                    if loading {
                        ListRow(title: "Reading the folder…", dimmed: true)
                    } else if let failure {
                        ListRow(title: "This folder could not be read: \(failure)", dimmed: true)
                    } else if shown.isEmpty {
                        ListRow(title: searching ? "Nothing matches “\(query)”." : "This folder is empty.", dimmed: true)
                    }
                    ForEach(shown, id: \.url) { row($0) }
                }
                .rise(1)
            }
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s3)
        }
        .scrollBounceBehavior(.basedOnSize)
        .canvas()
        .navigationTitle(directory.isEmpty ? (pick == nil ? "Game files" : "Choose a folder") : (directory as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Names in this folder")
        .searchScopes($scope) {
            Text("This folder").tag(Scope.folder)
            Text("Whole game").tag(Scope.game)
        }
        .toolbar {
            if let pick {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Use this folder") { pick(directory) }.tint(Theme.textPrimary)
                }
            }
        }
        .task { await load() }
        .task(id: "\(query)|\(scope)") { await search() }
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var shown: [Resolution] {
        guard searching else { return entries }
        return scope == .game ? results : entries.filter { name($0).localizedCaseInsensitiveContains(query) }
    }

    // MARK: Rows

    private func name(_ entry: Resolution) -> String { (entry.realRelativePath as NSString).lastPathComponent }

    private func tag(_ entry: Resolution) -> String {
        switch entry.layer.tier {
        case .original: "Game"
        case .rtp: "RTP"
        case .overrides where entry.layer.name.hasPrefix("overrides/mods/") || entry.layer.name.hasPrefix("overrides/translations/"): "Mod"
        default: "Prepared"
        }
    }

    @ViewBuilder private func row(_ entry: Resolution) -> some View {
        let label = rowLabel(entry)
        if entry.isDirectory {
            NavigationLink {
                GameFilesView(game: game, directory: entry.realRelativePath, resolver: loaded, pick: pick)
            } label: { label }
                .buttonStyle(.row)
        } else if pick != nil {
            label.opacity(0.5)
        } else {
            NavigationLink {
                GameFileDetail(entry: entry, tag: tag(entry), replacesOriginal: replaced.contains(entry.realRelativePath))
            } label: { label }
                .buttonStyle(.row)
                .contextMenu {
                    ShareLink(item: entry.url) { Label("Share", systemImage: "square.and.arrow.up") }
                }
        }
    }

    private func rowLabel(_ entry: Resolution) -> some View {
        HStack(spacing: Theme.s3) {
            Image(systemName: entry.isDirectory ? "folder" : "doc")
                .foregroundStyle(Theme.textSecondary).frame(width: 26).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(searching && scope == .game ? entry.realRelativePath : name(entry))
                    .font(Theme.value).foregroundStyle(Theme.textPrimary).lineLimit(2).truncationMode(.middle)
                if !entry.isDirectory {
                    Text(entry.size.formatted(.byteCount(style: .file))).font(.footnote).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: Theme.s2)
            if tag(entry) != "Game" {
                InfoPill(text: tag(entry))
            }
            if entry.isDirectory {
                Chevron()
            }
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s2)
        .frame(minHeight: Theme.rowHeight)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    // MARK: Sharing a folder

    @ViewBuilder private var zipRow: some View {
        GlassSection {
            HStack(spacing: Theme.s3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(zip.url == nil ? "Share this folder" : "ZIP ready").font(.subheadline).foregroundStyle(Theme.textPrimary)
                    if let progress = zip.progress {
                        ProgressView(value: progress).tint(Theme.textPrimary)
                    } else if let note = zip.note {
                        Text(note).font(.footnote).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Theme.s2)
                if let url = zip.url {
                    ShareLink(item: url) { Text("Share") }.buttonStyle(.link)
                } else if zip.progress == nil {
                    Button(zip.confirmLarge ? "Make it anyway" : "Make a ZIP") { Task { await makeZip() } }.buttonStyle(.link)
                }
            }
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s2)
            .frame(minHeight: Theme.rowHeight)
        }
    }

    struct FolderZip {
        var url: URL?
        var progress: Double?
        var note: String?
        var confirmLarge = false
    }

    /// The folder's merged files cloned into `tmp`, then zipped there; above 500 MB it asks once first.
    private func makeZip() async {
        guard let resolver = loaded else { return }
        let files = await Task.detached { Self.mergedFiles(under: directory, resolver: resolver) }.value
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        if total > 500 << 20, !zip.confirmLarge {
            zip.confirmLarge = true
            zip.note = "This folder holds \(total.formatted(.byteCount(style: .file))). The ZIP takes as much free space and a while to make."
            return
        }
        zip = FolderZip(progress: 0)
        let base = directory.isEmpty ? game.title : (directory as NSString).lastPathComponent
        let progress = ZipProgress(total: max(total, 1)) { value in zip.progress = value }
        let result = await Task.detached { () -> Result<URL, Error> in
            Result {
                let fm = FileManager.default
                let work = fm.temporaryDirectory.appending(path: "share-\(UUID().uuidString)", directoryHint: .isDirectory)
                let tree = work.appending(path: "tree", directoryHint: .isDirectory)
                defer { try? fm.removeItem(at: tree) }
                let skip = directory.isEmpty ? 0 : directory.count + 1
                for file in files {
                    let target = tree.appending(path: String(file.realRelativePath.dropFirst(skip)))
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: file.url, to: target) // APFS clones it
                }
                let destination = work.appending(path: "\(base).zip")
                try ArchiveWriter().zip(directory: tree, to: destination, prefix: base) { bytes, _ in progress.report(bytes) }
                return destination
            }
        }.value
        switch result {
        case let .success(url): zip = FolderZip(url: url)
        case let .failure(error): zip = FolderZip(note: "The ZIP could not be made: \(error.localizedDescription)")
        }
    }

    /// Every file under `directory` as the game sees it: the highest layer wins each path.
    nonisolated static func mergedFiles(under directory: String, resolver: OverlayResolver) -> [Resolution] {
        let prefix = directory.isEmpty ? "" : globLiteral(PathKey.normalize(directory)) + "/"
        var keys = Set<String>()
        for layer in resolver.layers {
            for entry in (try? resolver.index.glob(layer: layer.name, pattern: prefix + "*", limit: Int.max)) ?? [] where !entry.isDir {
                keys.insert(entry.key)
            }
        }
        return keys.sorted().compactMap { resolver.resolve($0) }
    }

    nonisolated static func globLiteral(_ text: String) -> String {
        text.map { "*?[".contains($0) ? "[\($0)]" : String($0) }.joined()
    }

    // MARK: Loading

    private func load() async {
        let resolver: OverlayResolver? = if let resolver { resolver } else { await model.gameFileResolver(for: game.id) }
        guard let resolver else {
            failure = "the game's file index is missing. Open the game once, then try again."
            loading = false
            return
        }
        loaded = resolver
        let directory = directory
        let (list, mods, summary) = await Task.detached { () -> ([Resolution], Set<String>, String?) in
            var list: [Resolution] = []
            for await entry in resolver.list(directory: directory) {
                list.append(entry)
            }
            list.sort { ($0.isDirectory ? 0 : 1, $0.realRelativePath.lowercased()) < ($1.isDirectory ? 0 : 1, $1.realRelativePath.lowercased()) }
            let mods = Set(list.filter { $0.layer.tier == .overrides && !$0.isDirectory }.map(\.realRelativePath).filter {
                (try? resolver.index.lookup(layer: "original", key: PathKey.normalize($0))) != nil
            })
            return (list, mods, directory.isEmpty ? Self.summary(resolver) : nil)
        }.value
        entries = list
        replaced = mods
        facts = summary
        loading = false
    }

    /// "1,204 files · 312 MB · 14 from mods", over the merged tree.
    nonisolated static func summary(_ resolver: OverlayResolver) -> String {
        let files = mergedFiles(under: "", resolver: resolver)
        let bytes = files.reduce(Int64(0)) { $0 + $1.size }
        let mods = files.count(where: { $0.layer.name.hasPrefix("overrides/mods/") || $0.layer.name.hasPrefix("overrides/translations/") })
        return "\(files.count.formatted()) file\(files.count == 1 ? "" : "s") · \(bytes.formatted(.byteCount(style: .file)))"
            + (mods > 0 ? " · \(mods) from mods" : "")
    }

    private func search() async {
        guard searching, scope == .game, let resolver = loaded else { results = []; return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let pattern = "*" + Self.globLiteral(query.lowercased()) + "*"
        let (found, cut) = await Task.detached { () -> ([Resolution], Bool) in
            var keys = Set<String>()
            for layer in resolver.layers {
                for entry in (try? resolver.index.glob(layer: layer.name, pattern: pattern, limit: 501)) ?? [] {
                    keys.insert(entry.key)
                }
            }
            return (keys.sorted().prefix(500).compactMap { resolver.resolve($0) }, keys.count > 500)
        }.value
        guard !Task.isCancelled else { return }
        results = found
        resultsCut = cut
    }
}

/// Reports zip progress to the main actor at most every 1 %.
private final class ZipProgress: @unchecked Sendable {
    let total: Int64
    let update: @MainActor (Double) -> Void
    private var last = 0.0

    init(total: Int64, update: @escaping @MainActor (Double) -> Void) {
        self.total = total
        self.update = update
    }

    func report(_ bytes: Int64) {
        let value = min(1, Double(bytes) / Double(total))
        guard value - last >= 0.01 else { return }
        last = value
        Task { @MainActor in update(value) }
    }
}

/// One file of the game: its name, size, where it comes from, and Share.
struct GameFileDetail: View {
    let entry: Resolution
    let tag: String
    let replacesOriginal: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s4) {
                Text((entry.realRelativePath as NSString).lastPathComponent).font(.title3.weight(.bold).monospaced())
                    .foregroundStyle(Theme.textPrimary).textSelection(.enabled).rise(0)
                GlassSection(footer: tag == "Mod" && replacesOriginal ? "Replaces the game's own file." : nil) {
                    ListRow(title: "Size") { RowValue(text: entry.size.formatted(.byteCount(style: .file))) }
                    ListRow(title: "From") { RowValue(text: tag) }
                    ListRow(title: "Path") { RowValue(text: entry.realRelativePath, mono: true) }
                }
                .rise(1)
                ShareLink(item: entry.url) { Label("Share", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.secondary)
                    .rise(2)
            }
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s3)
        }
        .scrollBounceBehavior(.basedOnSize)
        .canvas()
        .navigationTitle("File")
        .navigationBarTitleDisplayMode(.inline)
    }
}
