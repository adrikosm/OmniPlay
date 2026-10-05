import Diagnostics
import EasyRPGRuntime
import GameCore
import GameStore
import RuntimeCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    /// Nil until the first walk finishes, so zero never stands in for "still counting".
    @State private var storage: StorageSummary?
    @State private var bundleURL: URL?
    @State private var exporting = false
    @State private var exportError: String?
    @State private var footprint: UInt64 = 0
    @State private var everything: URL?
    @State private var testing: String?
    @AppStorage(AppModel.prepareBeforePlayKey) private var prepareMedia = true

    var body: some View {
        NavigationStack {
            ScrollView {
                Split(leadingWidth: 360) {
                    VStack(alignment: .leading, spacing: Theme.s6) {
                        Text("Settings").display(30).maskedRise().accessibilityAddTraits(.isHeader)
                        StorageHero(storage: storage)
                        GlassSection {
                            NavigationLink { EngineAssetsView() } label: {
                                ListRow(icon: "shippingbox", title: "Engine files", subtitle: engineSummary) { Chevron() }
                            }
                            .buttonStyle(.row)
                        }
                        .rise(4)
                        GlassSection(footer: "Videos, music and pictures an engine cannot play are converted once, after import "
                            + "or before the first play. Off, games start at once and skip what their engine cannot play.") {
                                ListRow(icon: "film.stack", title: "Prepare media before first play", minHeight: 44) {
                                    Toggle("Prepare media before first play", isOn: $prepareMedia).labelsHidden()
                                }
                            }
                            .rise(5)
                    }
                } trailing: {
                    VStack(alignment: .leading, spacing: Theme.s6) {
                        GlassSection(
                            "Support",
                            footer: exportError ?? "A diagnostics bundle holds this session's log and memory samples. "
                                + "It never includes game files or saves."
                        ) {
                            if let bundleURL {
                                ShareLink(item: bundleURL) {
                                    ListRow(icon: "square.and.arrow.up", title: "Share diagnostics bundle") { Chevron() }
                                }
                                .buttonStyle(.row)
                            } else {
                                Button { export() } label: {
                                    ListRow(icon: "square.and.arrow.up", title: exporting ? "Exporting…" : "Export diagnostics") {
                                        if exporting {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Chevron()
                                        }
                                    }
                                }
                                .buttonStyle(.row)
                                .disabled(exporting)
                            }
                            if let everything {
                                ShareLink(item: everything) {
                                    ListRow(icon: "shippingbox", title: "Share the backup") { Chevron() }
                                }
                                .buttonStyle(.row)
                            } else {
                                Button { backUpEverything() } label: {
                                    ListRow(
                                        icon: "shippingbox",
                                        title: testing == "export" ? "Backing up…" : "Back up everything",
                                        subtitle: "Saves, mods, settings and the library, in one ZIP"
                                    )
                                }
                                .buttonStyle(.row)
                                .disabled(testing != nil)
                            }
                            NavigationLink { LicencesView() } label: {
                                ListRow(icon: "doc.text", title: "Licences") { Chevron() }
                            }
                            .buttonStyle(.row)
                        }
                        GlassSection("About") {
                            ListRow(title: "Version") { RowValue(text: "\(Bundle.main.version) (\(Bundle.main.build))") }
                            ListRow(title: "Memory in use") { RowValue(text: Int64(footprint).formatted(.byteCount(style: .memory))) }
                            if let expiry = PhoneTesting.signingExpiry {
                                // A Personal Team build stops opening after seven days; rebuilding keeps every game and save.
                                ListRow(
                                    title: "Signed until",
                                    subtitle: expiry < .now.addingTimeInterval(2 * 86400) ? "Rebuild from your Mac soon" : nil
                                ) {
                                    RowValue(text: expiry.formatted(date: .abbreviated, time: .shortened))
                                }
                            }
                        }
                        GlassSection("Testing", footer: testingFooter) {
                            ForEach([8, 32], id: \.self) { size in
                                Button { makeLargeGame(size) } label: {
                                    ListRow(title: "Make a \(size) GB test game in Files")
                                }
                                .buttonStyle(.row)
                                .disabled(testing != nil)
                            }
                            Button { PhoneTesting.simulateMemoryWarning() } label: { ListRow(title: "Simulate a memory warning") }
                                .buttonStyle(.row)
                        }
                        #if DEBUG
                            DeveloperSection()
                        #endif
                    }
                    .rise(2)
                }
                .padding(.horizontal, Theme.s4)
                .padding(.top, Theme.s3)
                .padding(.bottom, 96)
            }
            .scrollBounceBehavior(.basedOnSize)
            .canvas()
            .toolbarVisibility(.hidden, for: .navigationBar)
            .task(id: model.phase) { await refresh() }
        }
    }

    /// "1 of 5 RTPs · GeneralUser GS"
    private var engineSummary: String {
        let installed = RTPFamily.allCases.count { RTPManager.isInstalled($0, paths: model.paths) }
        let font = MIDISoundFont.imported(paths: model.paths)?.deletingPathExtension().lastPathComponent ?? "GeneralUser GS"
        return "\(installed) of \(RTPFamily.allCases.count) RTPs · \(font)"
    }

    private var testingFooter: String {
        testing.map { $0 == "export" ? "Writing the backup…" : $0 }
            ?? "A synthetic game in On My iPhone → OmniPlay → Test games, for checking large imports; "
            + "most of its size is declared, not written."
    }

    private func makeLargeGame(_ gigabytes: Int) {
        testing = "Making the \(gigabytes) GB test game…"
        let documents = model.paths.exportsRoot.deletingLastPathComponent().deletingLastPathComponent()
        Task {
            let result = await Task.detached {
                Result { try PhoneTesting.makeLargeGame(gigabytes: gigabytes, documents: documents) { _ in } }
            }.value
            testing = nil
            exportError = (try? result.get()).map { _ in nil } ?? "The test game could not be made."
        }
    }

    private func backUpEverything() {
        guard let store = model.store else { return }
        testing = "export"
        let paths = model.paths
        Task {
            let result = await Task.detached { Result { try PhoneTesting.exportEverything(paths: paths, store: store) } }.value
            testing = nil
            switch result {
            case let .success(url): everything = url
            case let .failure(error): exportError = "The backup could not be written: \(error.localizedDescription)"
            }
        }
    }

    private func export() {
        exporting = true
        exportError = nil
        Task {
            do { bundleURL = try await HostSession.shared.exportBundle() } catch {
                exportError = "The bundle could not be written: \(error.localizedDescription)"
            }
            exporting = false
        }
    }

    private func refresh() async {
        footprint = MemoryProbe.footprint
        HostSession.shared.recordMemory(label: "settings")
        let paths = model.paths
        let store = model.store
        storage = await Task.detached { StorageSummary.compute(paths: paths, store: store) }.value
    }
}

/// Storage as one large number and one bar: what OmniPlay holds, split by kind, and what the phone has left.
private struct StorageHero: View {
    let storage: StorageSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Text("Storage used").font(.footnote.weight(.medium)).foregroundStyle(Theme.textSecondary).rise(1)
            if let storage {
                let parts: [StoragePart] = [
                    StoragePart("Games", storage.games, Theme.textPrimary),
                    StoragePart("Saves", storage.saves, Theme.textTertiary),
                    StoragePart("Other", storage.generated + storage.caches, Theme.fillStrong),
                ]
                let used = parts.reduce(0) { $0 + $1.bytes }
                Text(used.formatted(.byteCount(style: .file, spellsOutZero: false)))
                    .display(44)
                    .contentTransition(.numericText())
                    .maskedRise(1)
                if let available = storage.available {
                    Text("\(available.formatted(.byteCount(style: .file))) free on this iPhone")
                        .font(.footnote).foregroundStyle(Theme.textSecondary).rise(2)
                }
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(parts, id: \.name) { part in
                            Rectangle().fill(part.color)
                                .frame(width: max(
                                    part.bytes > 0 ? 3 : 0,
                                    (geo.size.width - 4) * CGFloat(part.bytes) / CGFloat(max(used, 1))
                                ))
                        }
                        Spacer(minLength: 0)
                    }
                    .clipShape(.capsule)
                }
                .frame(height: 6)
                .background(Theme.fill, in: .capsule)
                .wipeIn(delay: 0.3)
                .padding(.top, Theme.s3)
                .accessibilityHidden(true)
                let legend = ForEach(parts, id: \.name) { part in
                    HStack(spacing: 5) {
                        Circle().fill(part.color).frame(width: 7, height: 7)
                        Text("\(part.name) \(part.bytes.formatted(.byteCount(style: .file, spellsOutZero: false)))").fixedSize()
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.s3) { legend }
                    VStack(alignment: .leading, spacing: Theme.s1) { legend }
                }
                .font(.footnote.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                .accessibilityElement(children: .combine)
                .rise(3)
            } else {
                HStack(spacing: Theme.s2) {
                    ProgressView().controlSize(.small)
                    Text("Calculating…").font(.subheadline).foregroundStyle(Theme.textSecondary)
                }
                .frame(minHeight: 60)
            }
        }
    }
}

/// Byte totals for the Storage section. Directory sizes are walked lazily, never held as trees.
struct StorageSummary: Sendable {
    var games: Int64 = 0
    var saves: Int64 = 0
    var generated: Int64 = 0
    var caches: Int64 = 0
    var available: Int64?

    nonisolated static func compute(paths: AppPaths, store: GameStore?) -> StorageSummary {
        var s = StorageSummary()
        s.available = try? VolumeSpace.available(at: paths.root)
        s.caches = size(of: paths.cachesRoot)
        guard let store, let records = try? store.games.fetchAll(limit: 10000) else { return s }
        for game in records {
            s.games += game.installBytes
            s.saves += size(of: paths.tier(.saves, for: game.id))
            s.generated += size(of: paths.tier(.generated, for: game.id))
        }
        return s
    }

    private nonisolated static func size(of root: URL) -> Int64 {
        var total: Int64 = 0
        try? LazyDirectoryWalker.walk(root: root) { total += $0.fileSize; return .continue }
        return total
    }
}

/// Plain reference material: the components on the left, the selected one's entry in mono on the right.
struct LicencesView: View {
    @State private var selected = 0

    /// `THIRD-PARTY-LICENSES.txt` split into its entries: blank-line blocks after the two-block preamble.
    private static let entries: [(name: String, text: String)] = {
        guard let url = Bundle.main.url(forResource: "THIRD-PARTY-LICENSES", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [("Licences", "No licence index bundled.")] }
        let blocks = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }
        return blocks.dropFirst(2).map { block in
            let first = block.prefix { $0 != "\n" }
            let name = first.components(separatedBy: " — ").first?.components(separatedBy: " (").first ?? String(first)
            return (name.trimmingCharacters(in: .whitespaces), block)
        }
    }()

    var body: some View {
        Split(leadingWidth: 220) {
            ScrollView {
                GlassSection {
                    ForEach(Array(Self.entries.enumerated()), id: \.offset) { index, entry in
                        Button { withAnimation(Theme.quick) { selected = index } } label: {
                            ListRow(title: entry.name)
                                .background(index == selected ? Theme.fill : .clear)
                        }
                        .buttonStyle(.row)
                        .accessibilityAddTraits(index == selected ? .isSelected : [])
                    }
                }
                .padding(.bottom, Theme.s6)
            }
            .scrollIndicators(.hidden)
        } trailing: {
            ScrollView {
                let entry = Self.entries[min(selected, Self.entries.count - 1)]
                let lines = entry.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                VStack(alignment: .leading, spacing: Theme.s2) {
                    Text(lines.first ?? "").foregroundStyle(Theme.textPrimary)
                    if lines.count > 1 {
                        Text(lines[1].split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n"))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .font(Theme.mono)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .id(selected)
                .transition(.opacity)
            }
            .glass(radius: Theme.listRadius)
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s3)
        .canvas()
        .navigationTitle("Licences")
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension Bundle {
    var version: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    var build: String { infoDictionary?["CFBundleVersion"] as? String ?? "0" }
}

#if DEBUG
    /// Debug-only helpers for design review; compiled out of release builds.
    private struct DeveloperSection: View {
        @Environment(AppModel.self) private var model

        var body: some View {
            GlassSection("Developer") {
                Button {
                    if let store = model.store {
                        SampleLibrary.insert(into: store)
                    }
                } label: { ListRow(title: "Add sample library entries") }
                    .buttonStyle(.row)
                ListRow(title: "Session") { RowValue(text: HostSession.shared.sessionID.description, mono: true) }
            }
        }
    }
#endif

#if DEBUG
    enum SampleLibrary {
        static func insert(into store: GameStore) {
            struct Sample { let title: String, engine: EngineFamily, grade: PlayabilityGrade, confidence: Double }
            let samples = [
                Sample(title: "Lantern of the Deep", engine: .rpgMakerVXAce, grade: .loadable, confidence: 0.98),
                Sample(title: "Saltmarsh Letters", engine: .renpy, grade: .loadable, confidence: 0.97),
                Sample(title: "Orbital Bakery", engine: .rpgMakerMZ, grade: .loadable, confidence: 0.93),
                Sample(title: "Nine Rooms", engine: .html5, grade: .loadable, confidence: 0.71),
                Sample(title: "Ashen Compact", engine: .unityNative, grade: .refused, confidence: 0.99),
                Sample(title: "Meadow Ledger", engine: .rpgMaker2003, grade: .loadable, confidence: 0.9),
            ]
            for sample in samples {
                var g = GameRecord(title: sample.title, engine: sample.engine)
                g.compatibilityState = sample.grade
                g.detectionConfidence = sample.confidence
                g.installBytes = Int64.random(in: 40 << 20 ... 3 << 30)
                try? store.games.insert(g)
            }
        }
    }
#endif

/// One segment of the storage bar: what it is, its bytes, its colour.
private struct StoragePart {
    let name: String
    let bytes: Int64
    let color: Color
    init(_ name: String, _ bytes: Int64, _ color: Color) { (self.name, self.bytes, self.color) = (name, bytes, color) }
}
