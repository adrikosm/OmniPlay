import Diagnostics
import Foundation
import SwiftUI

/// The last 64 KiB of the session log as a terminal readout, newest at the bottom: time, level, source, message.
/// Only errors get colour. Never reads the whole file.
struct LogTailView: View {
    let url: URL?
    @State private var lines: [Line] = []
    @State private var level: Level = .all
    @State private var bundleURL: URL?
    @State private var exportError: String?

    enum Level: Hashable { case all, info, debug, errors }

    struct Line: Identifiable {
        let id: Int
        let time: String
        let level: String
        let source: String
        let message: String
        var isError: Bool { level == "error" || level == "fault" }

        func matches(_ filter: Level) -> Bool {
            switch filter {
            case .all: true
            case .info: level == "info" || level == "notice"
            case .debug: level == "debug"
            case .errors: isError
            }
        }

        /// `2026-09-25T06:27:00.782Z<TAB>info<TAB>runtime<TAB>message`; anything else is kept whole as the message.
        init(id: Int, raw: String) {
            self.id = id
            let parts = raw.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4 else {
                (time, level, source, message) = ("", "", "", raw)
                return
            }
            let stamp = parts[0]
            time = stamp.firstIndex(of: "T").map { String(stamp[stamp.index(after: $0)...].prefix(12)) } ?? stamp
            (level, source, message) = (parts[1], parts[2], parts[3])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            GlassSegmentBar(
                items: [(Level.all, "All"), (.info, "Info"), (.debug, "Debug"), (.errors, "Errors")],
                selection: $level,
                counts: Dictionary(uniqueKeysWithValues: [Level.all, .info, .debug, .errors].map { filter in
                    (filter, lines.count { $0.matches(filter) })
                })
            )
            .fixedSize()
            .rise(0)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.filter { $0.matches(level) }) { line in row(line) }
                    Text(lines.isEmpty ? "Nothing logged yet." : "End of session")
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, Theme.s4).padding(.vertical, 10)
                }
                .font(Theme.mono)
                .textSelection(.enabled)
                .padding(.vertical, Theme.s2)
            }
            .defaultScrollAnchor(.bottom)
            .glass(radius: Theme.listRadius)
            .rise(1)
            if let exportError {
                Text(exportError).font(.footnote).foregroundStyle(Theme.danger)
            }
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s3)
        .task { lines = await Self.tail(url).enumerated().map { Line(id: $0.offset, raw: $0.element) } }
        .navigationTitle("Session log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let bundleURL {
                    ShareLink(item: bundleURL) { Image(systemName: "square.and.arrow.up") }
                        .tint(Theme.textPrimary)
                        .accessibilityLabel("Share session bundle")
                } else if let dir = url?.deletingLastPathComponent() {
                    Button {
                        Task {
                            do { bundleURL = try await SessionBundle.export(sessionDirectory: dir) } catch {
                                exportError = error.localizedDescription
                            }
                        }
                    } label: { Image(systemName: "square.and.arrow.up") }
                        .tint(Theme.textPrimary)
                        .accessibilityLabel("Export session bundle")
                }
            }
        }
        .canvas()
    }

    private func row(_ line: Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(line.time).foregroundStyle(Theme.textTertiary).lineLimit(1).fixedSize().frame(minWidth: 96, alignment: .leading)
            Text(line.level).foregroundStyle(line.isError ? Theme.danger : Theme.textPrimary).frame(width: 44, alignment: .leading)
            Text(line.source).foregroundStyle(Theme.textSecondary).frame(width: 76, alignment: .leading).lineLimit(1)
            Text(line.message).foregroundStyle(line.isError ? Theme.dangerText : Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, 5)
        .background(line.isError ? Theme.danger.opacity(0.14) : .clear)
        .accessibilityElement(children: .combine)
    }

    nonisolated static let tailBytes = 64 << 10

    nonisolated static func tail(_ url: URL?) async -> [String] {
        guard let url else { return [] }
        return await Task.detached {
            guard let handle = try? FileHandle(forReadingFrom: url), let size = try? handle.seekToEnd() else { return [] }
            defer { try? handle.close() }
            let start = max(0, Int(size) - tailBytes)
            try? handle.seek(toOffset: UInt64(start))
            // A tail can start inside a multibyte character: its continuation bytes are skipped (that partial first
            // line is dropped below anyway), or the whole tail would fail to decode.
            guard let data = try? handle.readToEnd(), let text = String(bytes: data.drop { $0 & 0xC0 == 0x80 }, encoding: .utf8)
            else { return [] }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            if start > 0, !lines.isEmpty {
                lines.removeFirst()
            }
            return lines.suffix(500).map(\.self)
        }.value
    }
}
