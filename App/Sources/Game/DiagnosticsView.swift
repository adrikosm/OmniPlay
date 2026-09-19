import Diagnostics
import GameCore
import GameDetection
import GameStore
import SwiftUI

/// Everything OmniPlay knows about one game, without Xcode: what detection found, every session with its
/// verdict and peak memory, imports, media work pending, the save index, the last WebContent termination,
/// a memory summary and console errors from the newest session, plus log tails and a bundle export.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    let game: GameRecord
    let snapshot: DetectionSnapshot?
    @State private var data = Loaded()
    @State private var bundleURL: URL?
    @State private var copied = false

    struct Loaded: Sendable {
        var sessions: [SessionRecord] = []
        var imports: [ImportRecord] = []
        var media: [MediaJobRecord] = []
        var saves: [SaveMetaRecord] = []
        var termination: [String: String] = [:]
        var memory: MemorySummary?
        var consoleErrors: [String] = []
        var newestSession: URL?
    }

    struct MemorySummary: Sendable {
        var samples = 0
        var first: UInt64 = 0
        var peak: UInt64 = 0
        var last: UInt64 = 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s4) {
                section("Detection") {
                    if let snapshot {
                        line(DetectionExplainer.summary(snapshot.report))
                        row("Confidence", snapshot.report.confidence.formatted(.percent.precision(.fractionLength(0))))
                        row("Runtime", snapshot.resolution.selectedRuntime.map(DetectionExplainer.name) ?? "none")
                        if !snapshot.report.descriptor.warnings.isEmpty {
                            row("Warnings", "\(snapshot.report.descriptor.warnings.count)")
                        }
                    } else {
                        line("No detection report on disk. Re-import the game to rebuild it.")
                    }
                }
                section("Sessions") {
                    if data.sessions.isEmpty {
                        line("No sessions yet.")
                    }
                    ForEach(data.sessions.prefix(10)) { s in
                        row(
                            s.startedAt.formatted(date: .abbreviated, time: .shortened),
                            "\(s.teardownVerdict ?? "running")\(s.peakFootprint.map { " · peak \(Self.mib($0))" } ?? "")"
                        )
                    }
                }
                section("Memory (newest session)") {
                    if let m = data.memory {
                        row("Samples", "\(m.samples)")
                        row("Start", Self.mib(Int64(m.first)))
                        row("Peak", Self.mib(Int64(m.peak)))
                        row("End", Self.mib(Int64(m.last)))
                    } else {
                        line("No memory.jsonl yet.")
                    }
                }
                section("Last WebContent termination") {
                    if data.termination.isEmpty {
                        line("None recorded.")
                    }
                    ForEach(data.termination.keys.sorted(), id: \.self) { key in row(key, data.termination[key] ?? "") }
                }
                section("Console errors (newest session)") {
                    if data.consoleErrors.isEmpty {
                        line("None.")
                    }
                    ForEach(data.consoleErrors, id: \.self) {
                        Text($0).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.danger)
                    }
                }
                section("Media") {
                    if data.media.isEmpty {
                        line("Nothing to convert.")
                    }
                    ForEach(data.media, id: \.id) { job in row(job.inputRel, "\(job.state) → \(job.targetCodec)") }
                }
                section("Saves index") {
                    if data.saves.isEmpty {
                        line("No slot files indexed.")
                    }
                    ForEach(data.saves, id: \.id) { save in row(
                        save.slotKey,
                        "\(save.bytes.formatted(.byteCount(style: .file))) · \(save.family)"
                    ) }
                }
                section("Imports") {
                    if data.imports.isEmpty {
                        line("No import records.")
                    }
                    ForEach(data.imports, id: \.id) { imp in
                        row(imp.sourceName, "\(imp.container) · \(imp.bytes.formatted(.byteCount(style: .file))) · \(imp.outcome)")
                    }
                }
                if let newest = data.newestSession {
                    NavigationLink { LogTailView(url: newest.appending(path: "host.log")) } label: {
                        Label("Newest session log", systemImage: "doc.text.magnifyingglass").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .foregroundStyle(Theme.textPrimary).frame(minHeight: 44).padding(.horizontal, Theme.s4).glassCard(radius: 14)
                    HStack(spacing: Theme.s2) {
                        if let bundleURL {
                            ShareLink(item: bundleURL) {
                                Label("Share bundle", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                            }
                        } else {
                            Button { Task { bundleURL = try? await SessionBundle.export(sessionDirectory: newest) } } label: {
                                Label("Export bundle", systemImage: "archivebox").frame(maxWidth: .infinity)
                            }
                        }
                        Button {
                            UIPasteboard.general.string = summaryText
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy summary", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .foregroundStyle(Theme.textPrimary).frame(minHeight: 44).padding(.horizontal, Theme.s3).glassCard(radius: 14)
                }
            }
            .padding(Theme.s4)
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .inkScreen()
        .task { await load() }
    }

    // MARK: Pieces

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
            content()
        }
        .padding(Theme.s4).frame(maxWidth: .infinity, alignment: .leading).glassCard()
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).font(.footnote).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Spacer(minLength: Theme.s2)
            Text(value).font(.footnote).foregroundStyle(Theme.textPrimary).multilineTextAlignment(.trailing)
        }
    }

    private func line(_ text: String) -> some View { Text(text).font(.footnote).foregroundStyle(Theme.textSecondary) }

    static func mib(_ bytes: Int64) -> String { "\(bytes >> 20) MiB" }

    private var summaryText: String {
        var lines = ["OmniPlay diagnostics: \(game.title) (\(game.engine.rawValue))"]
        if let snapshot {
            lines.append(DetectionExplainer.summary(snapshot.report))
        }
        for s in data.sessions.prefix(5) {
            let peak = s.peakFootprint.map(Self.mib) ?? "n/a"
            lines.append("session \(s.startedAt.formatted(.iso8601)) \(s.teardownVerdict ?? "running") peak \(peak)")
        }
        if let m = data
            .memory {
            lines.append("memory start \(Self.mib(Int64(m.first))) peak \(Self.mib(Int64(m.peak))) end \(Self.mib(Int64(m.last)))")
        }
        lines += data.consoleErrors.prefix(10)
        return lines.joined(separator: "\n")
    }

    // MARK: Loading (tails only; nothing reads a whole log)

    private func load() async {
        guard let store = model.store else { return }
        let (paths, id) = (model.paths, game.id)
        data = await Task.detached { () -> Loaded in
            var out = Loaded()
            out.sessions = ((try? store.fetchAll(SessionRecord.self, game: id)) ?? []).sorted { $0.startedAt > $1.startedAt }
            out.imports = ((try? store.fetchAll(ImportRecord.self, game: id)) ?? []).sorted { $0.createdAt > $1.createdAt }
            out.media = (try? store.fetchAll(MediaJobRecord.self, game: id)) ?? []
            out.saves = (try? store.saves.fetch(game: id)) ?? []
            let gameLogs = paths.logs(game: id, session: UUID()).deletingLastPathComponent()
            let dirs = ((try? FileManager.default.contentsOfDirectory(
                at: gameLogs,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
            )) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted {
                    ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
                        ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                }
            guard let newest = dirs.first else { return out }
            out.newestSession = newest
            if let data = try? Data(contentsOf: newest.appending(path: "termination.json")),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                out.termination = dict.mapValues { "\($0)" }
            }
            out.memory = Self.summarize(newest.appending(path: "memory.jsonl"))
            out.consoleErrors = await LogTailView.tail(newest.appending(path: "web-console.log")).filter { $0.contains("\terror\t") }
                .suffix(20).map(\.self)
            return out
        }.value
    }

    /// Streams the JSON lines; the newest 10 000 samples are all the recorder keeps anyway.
    nonisolated static func summarize(_ url: URL) -> MemorySummary? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var summary = MemorySummary()
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8), let sample = try? JSONDecoder().decode(MemorySample.self, from: data),
                  let footprint = sample.footprintBytes else { continue }
            if summary.samples == 0 {
                summary.first = footprint
            }
            summary.samples += 1
            summary.peak = max(summary.peak, footprint)
            summary.last = footprint
        }
        return summary.samples == 0 ? nil : summary
    }
}
