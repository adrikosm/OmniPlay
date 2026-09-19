import Diagnostics
import GameCore
import GameStore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var storage = StorageSummary()
    @State private var bundleURL: URL?
    @State private var footprint: UInt64 = 0

    var body: some View {
        NavigationStack {
            List {
                Section("Storage") {
                    LabeledContent("Games", value: storage.games.formatted(.byteCount(style: .file, spellsOutZero: false)))
                    LabeledContent("Saves", value: storage.saves.formatted(.byteCount(style: .file, spellsOutZero: false)))
                    LabeledContent("Generated media", value: storage.generated.formatted(.byteCount(style: .file, spellsOutZero: false)))
                    LabeledContent("Caches", value: storage.caches.formatted(.byteCount(style: .file, spellsOutZero: false)))
                    LabeledContent(
                        "Available on device",
                        value: storage.available.map { $0.formatted(.byteCount(style: .file, spellsOutZero: false)) } ?? "Unknown"
                    )
                }
                Section {
                    if let bundleURL {
                        ShareLink(item: bundleURL) { Label("Share diagnostics bundle", systemImage: "square.and.arrow.up") }
                    } else {
                        Button { Task { bundleURL = try? await HostSession.shared.exportBundle() } } label: {
                            Label("Export diagnostics", systemImage: "waveform.path.ecg")
                        }
                    }
                    NavigationLink { LicencesView() } label: { Label("Licences", systemImage: "doc.text") }
                } header: {
                    Text("Support")
                } footer: {
                    Text("A diagnostics bundle holds this session's log and memory samples. It never includes game files or saves.")
                }
                Section("About") {
                    LabeledContent("Version", value: "\(Bundle.main.version) (\(Bundle.main.build))")
                    LabeledContent("Memory footprint", value: Int64(footprint).formatted(.byteCount(style: .memory)))
                }
                #if DEBUG
                    DeveloperSection()
                #endif
            }
            .listRowBackground(Color.white.opacity(0.05))
            .inkScreen()
            .navigationTitle("Settings")
            .task(id: model.phase) { await refresh() }
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
        s.caches = size(of: paths.caches())
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

struct LicencesView: View {
    private var text: String {
        guard let url = Bundle.main.url(forResource: "THIRD-PARTY-LICENSES", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "No licence index bundled." }
        return text
    }

    var body: some View {
        ScrollView {
            Text(text).font(.system(.footnote, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled).padding(Theme.s4).frame(maxWidth: .infinity, alignment: .leading)
        }
        .inkScreen()
        .navigationTitle("Licences")
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
            Section("Developer") {
                Button("Add sample library entries") {
                    if let store = model.store {
                        SampleLibrary.insert(into: store)
                    }
                }
                LabeledContent("Session", value: HostSession.shared.sessionID.description).font(.footnote)
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
