import Foundation
import SwiftUI

/// The in-game menu: Resume, Logs, Exit. Presented while the runtime is paused; dismissing resumes.
struct PauseMenu: View {
    let title: String
    @Binding var controlsVisible: Bool
    @Binding var controlsOpacity: Double
    @Binding var hideWithController: Bool
    let controllerConnected: Bool
    let logURL: URL?
    let onResume: () -> Void
    let onExit: () -> Void
    @State private var confirmExit = false
    @State private var showLogs = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.s4) {
                Text(title).font(Theme.title(24)).foregroundStyle(Theme.textPrimary).lineLimit(2)
                Text("Paused").font(.subheadline).foregroundStyle(Theme.textSecondary)
                Button("Resume", systemImage: "play.fill", action: onResume).buttonStyle(LanternButtonStyle()).frame(maxWidth: .infinity)
                    .padding(.top, Theme.s2)
                VStack(spacing: 0) {
                    Toggle(isOn: $controlsVisible) {
                        Label("Touch controls", systemImage: "gamecontroller")
                    }
                    .tint(Theme.lantern)
                    .padding(Theme.s4)
                    Divider().overlay(Theme.hairline)
                    HStack {
                        Label("Opacity", systemImage: "circle.lefthalf.filled")
                        Slider(value: $controlsOpacity, in: 0.2 ... 1.0).tint(Theme.lantern).disabled(!controlsVisible)
                    }
                    .padding(Theme.s4)
                    Divider().overlay(Theme.hairline)
                    Toggle(isOn: $hideWithController) {
                        Label(
                            controllerConnected ? "Hide while a controller is connected" : "Hide with a controller",
                            systemImage: "gamecontroller.fill"
                        )
                    }
                    .tint(Theme.lantern)
                    .padding(Theme.s4)
                    Divider().overlay(Theme.hairline)
                    Button { showLogs = true } label: {
                        Label("Session log", systemImage: "doc.text.magnifyingglass").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(Theme.s4)
                }
                .foregroundStyle(Theme.textPrimary)
                .glassCard()
                Spacer(minLength: 0)
                Button(role: .destructive) { confirmExit = true } label: {
                    Label("Leave game", systemImage: "rectangle.portrait.and.arrow.right").frame(maxWidth: .infinity)
                }
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(Theme.danger)
                .frame(minHeight: 50)
                .glassCard(radius: 25)
            }
            .padding(Theme.s4)
            .inkScreen()
            .navigationDestination(isPresented: $showLogs) { LogTailView(url: logURL) }
            .confirmationDialog("Leave the game?", isPresented: $confirmExit, titleVisibility: .visible) {
                Button("Leave", role: .destructive, action: onExit)
            } message: {
                Text("RPG Maker games write their autosave slot first. Other games keep only what they already saved.")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.ultraThinMaterial)
        .preferredColorScheme(.dark)
    }
}

/// The last 64 KiB of the session log, newest lines at the bottom. Never reads the whole file.
struct LogTailView: View {
    let url: URL?
    @State private var lines: [String] = []
    @State private var bundleURL: URL?
    @State private var exportError: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(line).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(line.contains("\terror\t") ? Theme.danger : Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading).id(i)
                    }
                }
                .padding(Theme.s3)
                .textSelection(.enabled)
            }
            .task {
                lines = await Self.tail(url)
                if let last = lines.indices.last {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
        .navigationTitle("Session log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let bundleURL {
                    ShareLink(item: bundleURL) { Label("Share bundle", systemImage: "square.and.arrow.up") }
                } else if let dir = url?.deletingLastPathComponent() {
                    Button("Export session bundle", systemImage: "archivebox") {
                        Task {
                            do { bundleURL = try await SessionBundle.export(sessionDirectory: dir) } catch {
                                exportError = error.localizedDescription
                            }
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let exportError {
                Text(exportError).font(.footnote).foregroundStyle(Theme.danger).padding(Theme.s3).glassCard(radius: 12).padding()
            }
        }
        .inkScreen()
        .overlay {
            if lines.isEmpty {
                Text("Nothing logged yet.").foregroundStyle(Theme.textSecondary)
            }
        }
    }

    nonisolated static let tailBytes = 64 << 10

    nonisolated static func tail(_ url: URL?) async -> [String] {
        guard let url else { return [] }
        return await Task.detached {
            guard let handle = try? FileHandle(forReadingFrom: url), let size = try? handle.seekToEnd() else { return [] }
            defer { try? handle.close() }
            let start = max(0, Int(size) - tailBytes)
            try? handle.seek(toOffset: UInt64(start))
            guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return [] }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            if start > 0, !lines.isEmpty {
                lines.removeFirst()
            }
            return lines.suffix(500).map(\.self)
        }.value
    }
}
