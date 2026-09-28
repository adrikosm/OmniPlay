import EasyRPGRuntime
import GameCore
import RuntimeCore
import SwiftUI
import UniformTypeIdentifiers

/// RTPs and the MIDI soundfont: engine files OmniPlay cannot ship (RTPs belong to whoever installed RPG Maker) or
/// ships a default for (GeneralUser GS). Both are copied in from Files.
struct EngineAssetsView: View {
    @Environment(AppModel.self) private var model
    @State private var importing: RTPFamily?
    @State private var pickingRTP = false
    @State private var pickingFont = false
    @State private var busy: String?
    @State private var message: String?
    @State private var refresh = 0

    var body: some View {
        ScrollView {
            Split {
                GlassSection("RPG Maker RTPs") {
                    ForEach(RTPFamily.allCases, id: \.self) { family in
                        rtpRow(family)
                    }
                }
                .rise(0)
            } trailing: {
                VStack(alignment: .leading, spacing: Theme.s4) {
                    let imported = MIDISoundFont.imported(paths: model.paths)
                    GlassSection("MIDI music") {
                        ListRow(
                            title: "Soundfont",
                            subtitle: imported.map { "\($0.deletingPathExtension().lastPathComponent), imported" }
                                ?? "GeneralUser GS, built in"
                        )
                        Button("Import a soundfont") { pickingFont = true }
                            .buttonStyle(.link)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Theme.s4)
                        if imported != nil {
                            Button("Use the built-in soundfont") {
                                run("Removing…") {
                                    try MIDISoundFont.removeImported(paths: model.paths)
                                    return "Back to GeneralUser GS."
                                }
                            }
                            .buttonStyle(.link)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Theme.s4)
                        }
                    }
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, Theme.s4)
                            .transition(.opacity)
                    }
                    Text("Older RPG Maker games use shared art and music from the RTP. OmniPlay can't include it, so import the "
                        + "RTP folder from your own copy of RPG Maker. 2000 and 2003 RTPs are recognised by their files, including "
                        +
                        "translated releases. MIDI music (2000, 2003, XP and VX) plays through the soundfont from the next game you start.")
                        .font(.footnote).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Theme.s4)
                }
                .rise(1)
            }
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s3)
        }
        .id(refresh)
        .disabled(busy != nil)
        .overlay {
            if let busy {
                HStack(spacing: Theme.s3) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.subheadline).foregroundStyle(Theme.textPrimary)
                }
                .padding(.horizontal, Theme.s6).padding(.vertical, Theme.s4)
                .glass(radius: Theme.listRadius, heavy: true)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(Theme.quick, value: busy)
        .navigationTitle("Engine files")
        .navigationBarTitleDisplayMode(.inline)
        .canvas()
        .fileImporter(isPresented: $pickingRTP, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result, let family = importing {
                importRTP(url, as: family)
            }
        }
        .fileImporter(isPresented: $pickingFont, allowedContentTypes: [UTType(filenameExtension: "sf2") ?? .data]) { result in
            if case let .success(url) = result {
                run("Copying the soundfont…") {
                    try await scoped(url) { try await MIDISoundFont.install(from: url, paths: model.paths) }
                    return "Using \(url.deletingPathExtension().lastPathComponent) for MIDI."
                }
            }
        }
    }

    /// Import, or a check and "Installed" (the release it matched as the subtitle). Touch and hold to remove.
    private func rtpRow(_ family: RTPFamily) -> some View {
        let installed = RTPManager.isInstalled(family, paths: model.paths)
        return ListRow(title: family.title, subtitle: installed ? RTPManager.variant(family, paths: model.paths) : nil) {
            if installed {
                Label("Installed", systemImage: "checkmark")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            } else {
                Button("Import") {
                    importing = family
                    pickingRTP = true
                }
                .buttonStyle(.link)
            }
        }
        .contextMenu {
            if installed {
                Button("Import again", systemImage: "square.and.arrow.down") {
                    importing = family
                    pickingRTP = true
                }
                Button("Remove", systemImage: "trash", role: .destructive) {
                    run("Removing…") {
                        try RTPManager.remove(family, paths: model.paths)
                        return "Removed the \(family.title) RTP."
                    }
                }
            }
        }
    }

    /// 2000 and 2003 RTPs are fingerprinted before the copy, so one picked under the wrong row still lands where
    /// its games look for it.
    private func importRTP(_ url: URL, as chosen: RTPFamily) {
        run("Copying the RTP…") {
            try await scoped(url) {
                var family = chosen
                var match: EasyRPGRTPMatch?
                if chosen == .rpg2000 || chosen == .rpg2003 {
                    let root = try RTPManager.locateRoot(in: url, family: chosen)
                    match = await Task.detached { EasyRPGRTPMatch.identify(root) }.value
                    family = match?.family ?? chosen
                }
                let files = try await RTPManager.install(from: url, family: family, paths: model.paths)
                RTPManager.recordVariant(match?.summary, family: family, paths: model.paths)
                var note = "Imported \(files) files into the \(family.title) RTP."
                if family != chosen {
                    note += " The folder is the \(family.title) RTP, not \(chosen.title)."
                } else if match == nil, chosen == .rpg2000 || chosen == .rpg2003 {
                    note += " Its files match no RTP release OmniPlay knows; games will still look in it."
                }
                return note
            }
        }
    }

    private func run(_ label: String, _ work: @escaping @MainActor () async throws -> String) {
        busy = label
        Task {
            do {
                message = try await work()
            } catch let RTPManager.ImportError.notAnRTP(found) {
                message = "That folder doesn't look like an RTP (it has \(found.joined(separator: ", ")))."
            } catch {
                message = error.localizedDescription
            }
            busy = nil
            refresh += 1
        }
    }

    private func scoped<T>(_ url: URL, _ body: () async throws -> T) async rethrows -> T {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try await body()
    }
}

private extension RTPFamily {
    var title: String {
        switch self {
        case .xp: "RPG Maker XP"
        case .vx: "RPG Maker VX"
        case .vxAce: "RPG Maker VX Ace"
        case .rpg2000: "RPG Maker 2000"
        case .rpg2003: "RPG Maker 2003"
        }
    }
}
