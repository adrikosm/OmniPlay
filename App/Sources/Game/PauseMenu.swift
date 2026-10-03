import Foundation
import RuntimeCore
import SwiftUI
import UIKit

/// The in-game menu over the held game: the frame blurred behind, the title and a large Resume on the left, grouped
/// lists sliding in on the right. Presented without the system slide; everything animates in by itself and fades
/// out before it goes. Resuming, the controls editor and leaving all close it.
struct PauseMenu: View {
    let title: String
    /// The paused game's own picture, blurred once, shown behind the menu so pausing reads as the game held still.
    var backdrop: UIImage?
    /// "12 min played" for this session.
    var played: String?
    /// True when the session offers a host pad, including optional keyboard controls for Godot.
    let hasTouchControls: Bool
    @Binding var controlsVisible: Bool
    @Binding var controlsOpacity: Double
    let controllerConnected: Bool
    let logURL: URL?
    /// 1 when off, 2...9 while the engine paces itself faster. Absent for runtimes that cannot.
    let fastForward: Int?
    /// The row's title and labels: multipliers, or Ren'Py's skip modes.
    let speed: SpeedChoices
    let onFastForward: (Int) -> Void
    /// The engine's own menu (ScummVM's save/load/options), when the runtime has one.
    let engineMenu: String?
    let onEngineMenu: () -> Void
    /// Game Tools for the running game (variables, cheats, diagnostics), pushed inside this menu.
    let gameTools: GameToolsView?
    /// Opens the layout editor over the paused game.
    let onEditControls: () -> Void
    /// Takes and saves a screenshot; answers what happened.
    let onScreenshot: () async -> String
    let onResume: () -> Void
    let onExit: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var confirmExit = false
    @State private var screenshotResult: String?
    @State private var takingScreenshot = false
    @AppStorage(Haptics.intensityKey) private var haptics = 0.7
    @State private var showLogs = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Split(spacing: 36, leadingWidth: 360) {
                    session
                } trailing: {
                    if shown {
                        lists
                            .frame(maxHeight: .infinity, alignment: .center)
                            .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, Theme.s6)
                .padding(.vertical, Theme.s4)
                .frame(maxWidth: 1000)
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.vertical, alignment: .center) { height, _ in height }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollContentBackground(.hidden)
            .toolbarVisibility(.hidden, for: .navigationBar)
            .background { backdropView }
            .navigationDestination(isPresented: $showLogs) { LogTailView(url: logURL) }
            .confirmationDialog("Leave the game?", isPresented: $confirmExit, titleVisibility: .visible) {
                Button("Leave", role: .destructive) { close(then: onExit) }
            } message: {
                Text("RPG Maker games write their autosave slot first. Other games keep only what they already saved.")
            }
        }
        .presentationBackground(.clear)
        .preferredColorScheme(.dark)
        .onAppear { withAnimation(Theme.motion(Theme.sheet, reduce: reduceMotion)) { shown = true } }
    }

    /// The held frame under a heavy blur and a dark veil, fading in behind the menu.
    private var backdropView: some View {
        ZStack {
            Theme.canvas
            if let backdrop, !reduceTransparency {
                Image(uiImage: backdrop).resizable().scaledToFill().blur(radius: 14).transition(.opacity)
            }
            Theme.canvas.opacity(reduceTransparency ? 1 : 0.72)
        }
        .opacity(shown ? 1 : 0)
        .animation(.easeOut(duration: 0.35), value: backdrop != nil)
        .ignoresSafeArea()
    }

    /// The fade-out first, then the action (resume, editor, leave), so nothing cuts away.
    private func close(then action: @escaping () -> Void) {
        withAnimation(Theme.quick) { shown = false } completion: { action() }
    }

    // MARK: Left

    private var session: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(played.map { "Paused · \($0)" } ?? "Paused").font(.footnote.weight(.medium)).foregroundStyle(Theme.textSecondary)
                .rise(0)
            Text(title)
                .display(46)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                .minimumScaleFactor(0.6)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.s2)
                .maskedRise(1)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 10) {
                Button { close(then: onResume) } label: { Label("Resume", systemImage: "play.fill").padding(.horizontal, Theme.s2) }
                    .buttonStyle(PillButtonStyle(kind: .accent, height: 52))
                Button {
                    takingScreenshot = true
                    Task {
                        screenshotResult = await onScreenshot()
                        takingScreenshot = false
                    }
                } label: {
                    Image(systemName: takingScreenshot ? "hourglass" : "camera").contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.round(52))
                .disabled(takingScreenshot)
                .accessibilityLabel("Take a screenshot")
            }
            .padding(.top, 22)
            .rise(3)
            if let screenshotResult {
                Text(screenshotResult).font(.footnote).foregroundStyle(Theme.textSecondary)
                    .padding(.top, Theme.s2).transition(.opacity)
            }
            if let fastForward {
                VStack(alignment: .leading, spacing: Theme.s2) {
                    Text(speed.title).font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    GlassSegmentBar(
                        items: speed.options.map { ($0.value, $0.label) },
                        selection: Binding(get: { fastForward }, set: onFastForward)
                    )
                    .fixedSize()
                }
                .padding(.top, 22)
                .rise(4)
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    // MARK: Right

    private var lists: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            GlassSection {
                if let gameTools {
                    NavigationLink { gameTools } label: {
                        ListRow(icon: "slider.horizontal.3", title: "Game Tools", minHeight: 44) { Chevron() }
                    }
                    .buttonStyle(.row)
                }
                if hasTouchControls {
                    Button { close(then: onEditControls) } label: {
                        ListRow(
                            icon: "gamecontroller",
                            title: "Controls",
                            subtitle: controllerConnected ? "Controller connected" : nil,
                            minHeight: 44
                        ) {
                            Chevron()
                        }
                    }
                    .buttonStyle(.row)
                }
                if let engineMenu {
                    Button { close(then: onEngineMenu) } label: {
                        ListRow(icon: "list.bullet.rectangle", title: engineMenu, minHeight: 44) { Chevron() }
                    }
                    .buttonStyle(.row)
                }
            }
            if hasTouchControls {
                GlassSection {
                    ListRow(title: "Touch controls", minHeight: 44) {
                        Toggle("Touch controls", isOn: $controlsVisible).labelsHidden()
                    }
                    ListRow(title: "Opacity", minHeight: 44) {
                        Slider(value: $controlsOpacity, in: 0.2 ... 1.0).tint(Theme.textPrimary).frame(maxWidth: 170)
                            .disabled(!controlsVisible).accessibilityLabel("Touch control opacity")
                    }
                    ListRow(title: "Haptics", minHeight: 44) {
                        Picker("Haptics", selection: $haptics) {
                            Text("Off").tag(0.0)
                            Text("Light").tag(0.4)
                            Text("Normal").tag(0.7)
                            Text("Strong").tag(1.0)
                        }
                        .pickerStyle(.menu)
                        .tint(Theme.textSecondary)
                    }
                }
            }
            GlassSection {
                Button { showLogs = true } label: {
                    ListRow(icon: "doc.text", title: "Session log", minHeight: 44) { Chevron() }
                }
                .buttonStyle(.row)
                Button { confirmExit = true } label: {
                    HStack(spacing: Theme.s3) {
                        Image(systemName: "xmark").font(.body).frame(width: 26).accessibilityHidden(true)
                        Text("Leave game").font(.subheadline)
                        Spacer()
                    }
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, Theme.s4)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.row)
                .accessibilityLabel("Leave game")
            }
        }
    }
}

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

    private var shown: [Line] {
        switch level {
        case .all: lines
        case .info: lines.filter { $0.level == "info" || $0.level == "notice" }
        case .debug: lines.filter { $0.level == "debug" }
        case .errors: lines.filter(\.isError)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            GlassSegmentBar(
                items: [(Level.all, "All"), (.info, "Info"), (.debug, "Debug"), (.errors, "Errors")],
                selection: $level,
                counts: [
                    .all: lines.count, .info: lines.count { $0.level == "info" || $0.level == "notice" },
                    .debug: lines.count { $0.level == "debug" }, .errors: lines.count(where: \.isError),
                ]
            )
            .fixedSize()
            .rise(0)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { line in row(line) }
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
            Text(line.message).foregroundStyle(line.isError ? Color(hex: 0xFFB3AE) : Theme.textPrimary)
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
