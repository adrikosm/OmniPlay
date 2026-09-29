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
        /// Sessions whose log folder holds a MetricKit crash or hang report.
        var crashReports: Set<UUID> = []
    }

    struct MemorySummary: Sendable {
        var samples = 0
        var first: UInt64 = 0
        var peak: UInt64 = 0
        var last: UInt64 = 0
        /// The session in up to 14 equal slices, each its highest footprint, for the bar chart.
        var bars: [UInt64] = []
        var seconds: Double = 0
    }

    var body: some View {
        ScrollView {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Theme.s4) {
                    detection.frame(minWidth: 240, maxWidth: .infinity)
                    memory.frame(minWidth: 240, maxWidth: .infinity)
                    checks.frame(minWidth: 240, maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: Theme.s6) {
                    detection
                    memory
                    checks
                }
            }
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s3)
        }
        .scrollBounceBehavior(.basedOnSize)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .canvas()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { shareMenu }
        }
        .task { await load() }
    }

    // MARK: Columns

    private var detection: some View {
        GlassSection("Detection") {
            if let snapshot {
                VStack(alignment: .leading, spacing: Theme.s2) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.s2) {
                        Text(snapshot.report.confidence.formatted(.percent.precision(.fractionLength(0)))).display(40)
                            .contentTransition(.numericText())
                        Text("confidence").font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                    Text(DetectionExplainer.summary(snapshot.report)).font(.subheadline).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.s4)
                ListRow(title: "Runtime") { RowValue(text: snapshot.resolution.selectedRuntime.map(DetectionExplainer.name) ?? "None") }
                if !snapshot.report.descriptor.warnings.isEmpty {
                    ListRow(title: "Warnings") { RowValue(text: "\(snapshot.report.descriptor.warnings.count)") }
                }
            } else {
                ListRow(title: "No detection report on disk", subtitle: "Import the game again to rebuild it.", dimmed: true)
            }
        }
        .rise(0)
    }

    private var memory: some View {
        VStack(alignment: .leading, spacing: Theme.s6) {
            GlassSection("Memory, newest session") {
                if let m = data.memory {
                    VStack(spacing: Theme.s2) {
                        MemoryBars(bars: m.bars, peak: m.peak)
                        HStack {
                            Text("\(Int(m.seconds.rounded())) s").font(Theme.mono).foregroundStyle(Theme.textTertiary)
                            Spacer()
                            Text("Peak \(Self.mib(Int64(m.peak)))").font(.footnote).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .padding(Theme.s4)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "Memory: start \(Self.mib(Int64(m.first))), peak \(Self.mib(Int64(m.peak))), end \(Self.mib(Int64(m.last)))"
                    )
                } else {
                    ListRow(title: "No memory samples yet", dimmed: true)
                }
            }
            GlassSection("Sessions") {
                if data.sessions.isEmpty {
                    ListRow(title: "No sessions yet", dimmed: true)
                }
                ForEach(data.sessions.prefix(6)) { s in
                    let crashed = s.teardownVerdict == "endedUnexpectedly" || (s.notes ?? "").hasPrefix("crash")
                    ListRow(
                        title: s.startedAt.dayAndTime,
                        subtitle: s.peakFootprint.map { "Peak \(Self.mib($0))" }
                            .map { data.crashReports.contains(s.id) ? $0 + " · crash report" : $0 }
                    ) {
                        Text(s.teardownVerdict == nil ? "Running" : crashed ? "Closed unexpectedly" : "Ended normally")
                            .font(.footnote).foregroundStyle(crashed ? Theme.danger : Theme.textSecondary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .rise(1)
    }

    private var checks: some View {
        GlassSection("Checks") {
            ListRow(title: "Console errors") {
                Text(data.consoleErrors.isEmpty ? "None" : "\(data.consoleErrors.count)")
                    .font(.footnote).foregroundStyle(data.consoleErrors.isEmpty ? Theme.textSecondary : Theme.danger)
            }
            ForEach(data.consoleErrors.prefix(4), id: \.self) { line in
                Text(line.split(separator: "\t").last.map(String.init) ?? line)
                    .font(Theme.mono).foregroundStyle(Color(hex: 0xFFB3AE)).lineLimit(2)
                    .padding(.horizontal, Theme.s4).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.danger.opacity(0.12))
            }
            ListRow(title: "Media") {
                RowValue(text: data.media.isEmpty ? "Nothing to convert" : "\(data.media.count) to convert")
            }
            ListRow(title: "Save index") {
                RowValue(text: data.saves.isEmpty ? "No slots yet" : "\(data.saves.count) slot\(data.saves.count == 1 ? "" : "s")")
            }
            if let imp = data.imports.first {
                ListRow(title: "Import") {
                    RowValue(text: "\(imp.container.capitalizedFirst) · \(imp.bytes.formatted(.byteCount(style: .file)))")
                }
            }
            if let reason = data.termination["reason"] ?? data.termination.values.first {
                ListRow(title: "Web view ended", subtitle: reason)
            }
            if let newest = data.newestSession {
                NavigationLink { LogTailView(url: newest.appending(path: "host.log")) } label: {
                    ListRow(title: "Newest session log") { Chevron() }
                }
                .buttonStyle(.row)
            }
        }
        .rise(2)
    }

    /// Export the newest session's bundle, or copy a plain-text summary.
    private var shareMenu: some View {
        Menu {
            if let bundleURL {
                ShareLink(item: bundleURL) { Label("Share session bundle", systemImage: "square.and.arrow.up") }
            } else if let newest = data.newestSession {
                Button("Export session bundle", systemImage: "archivebox") {
                    Task { bundleURL = try? await SessionBundle.export(sessionDirectory: newest) }
                }
            }
            Button(copied ? "Copied" : "Copy summary", systemImage: copied ? "checkmark" : "doc.on.doc") {
                UIPasteboard.general.string = summaryText
                copied = true
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .tint(Theme.textPrimary)
        .accessibilityLabel("Share")
    }

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
            // Ordered in the query: sorting a capped, unordered page dropped the newest sessions of a long-played game.
            out.sessions = (try? store.sessions.recent(game: id)) ?? []
            out.imports = (try? store.imports.recent(game: id)) ?? []
            out.media = (try? store.fetchAll(MediaJobRecord.self, game: id)) ?? []
            out.saves = (try? store.saves.fetch(game: id)) ?? []
            out.crashReports = Set(out.sessions.prefix(10).map(\.id).filter { session in
                let files = (try? FileManager.default
                    .contentsOfDirectory(atPath: paths.logs(game: id, session: session).path(percentEncoded: false))) ?? []
                return files.contains { $0.hasPrefix("metrickit-") }
            })
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
        // The recorder writes ISO 8601 timestamps; the default decoder expects seconds and rejected every line.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var summary = MemorySummary()
        var points: [(Date, UInt64)] = []
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8), let sample = try? decoder.decode(MemorySample.self, from: data),
                  let footprint = sample.footprintBytes else { continue }
            if summary.samples == 0 {
                summary.first = footprint
            }
            summary.samples += 1
            summary.peak = max(summary.peak, footprint)
            summary.last = footprint
            points.append((sample.timestamp, footprint))
        }
        guard let start = points.first?.0, let end = points.last?.0 else { return nil }
        summary.seconds = end.timeIntervalSince(start)
        let slices = min(14, points.count)
        summary.bars = (0 ..< slices).map { i in
            points[(i * points.count / slices) ..< ((i + 1) * points.count / slices)].map(\.1).max() ?? 0
        }
        return summary
    }
}

/// The newest session's memory as bars that grow up from the baseline, one after another. The peak is white; the
/// rest stay dim so the eye goes straight to it.
private struct MemoryBars: View {
    let bars: [UInt64]
    let peak: UInt64
    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let peakIndex = bars.firstIndex(of: peak)
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(Array(bars.enumerated()), id: \.offset) { index, value in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(index == peakIndex ? Theme.textPrimary : Theme.fillStrong)
                    .frame(maxWidth: 14)
                    .frame(height: max(4, 58 * CGFloat(value) / CGFloat(max(peak, 1))))
                    .scaleEffect(y: grown || reduceMotion ? 1 : 0.02, anchor: .bottom)
                    .animation(Theme.motion(Theme.wipe, reduce: reduceMotion).delay(0.2 + 0.04 * Double(index)), value: grown)
            }
        }
        .frame(height: 58, alignment: .bottom)
        .frame(maxWidth: .infinity)
        .onAppear { grown = true }
    }
}
