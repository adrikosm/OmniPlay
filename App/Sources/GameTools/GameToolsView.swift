import GameCore
import GameDetection
import GameStore
import GameTools
import SwiftUI

/// The Game Tools control centre for one game: the sections its capabilities allow, each either open or disabled with
/// the reason. Reached from game detail and from the in-game pause menu. Nothing here asks which engine the game uses;
/// `GameToolsCapabilityResolver` decides (`Scripts/check-no-engine-checks-in-views.sh`).
struct GameToolsView: View {
    @Environment(AppModel.self) private var model
    let game: GameRecord
    let snapshot: DetectionSnapshot?
    @State private var open: ToolsSection?
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var typeSize

    private var running: Bool { model.playing?.id == game.id && model.tools != nil }

    private var capabilities: GameToolsCapabilities {
        let playable = snapshot?.report.outcome.isPlayableClass == true && snapshot?.resolution.selectedRuntime != nil
        let session: GameToolsCapabilityResolver.Session = if running, let tools = model.tools {
            .running(state: tools.capabilities)
        } else {
            .notRunning
        }
        let stores = !SaveStrategy.forEngine(game.engine, generation: game.generation).persistentStores.isEmpty
        return GameToolsCapabilityResolver.resolve(engine: game.engine, playable: playable, hasPersistentData: stores, session: session)
    }

    var body: some View {
        let capabilities = capabilities
        let groups = Self.groups.map { group in capabilities.sections.filter { group.contains($0.section) } }.filter { !$0.isEmpty }
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(running ? "Changes apply to the running game and can be undone." : "Start the game to change live values.")
                        .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: Theme.s3)
                    // The hub stays in view; the section used last is one tap away rather than opened for the player.
                    if let raw = UserDefaults.standard.string(forKey: lastSectionKey), let last = ToolsSection(rawValue: raw),
                       capabilities.availability(of: last) == .available {
                        Button("Back to \(last.title)") { open = last }.buttonStyle(.link)
                    }
                }
                .rise(0)
                // Live changes, then the game's files, then how it runs; landscape sets them side by side.
                if Adaptive.wide(vertical: verticalSizeClass, horizontal: horizontalSizeClass, type: typeSize) {
                    HStack(alignment: .top, spacing: Theme.s4) {
                        VStack(spacing: Theme.s4) { ForEach(Array(groups.enumerated()).filter { $0.offset != 1 }, id: \.offset) { section(
                            $0.element,
                            step: $0.offset
                        ) } }
                        VStack(spacing: Theme.s4) { ForEach(Array(groups.enumerated()).filter { $0.offset == 1 }, id: \.offset) { section(
                            $0.element,
                            step: $0.offset
                        ) } }
                    }
                } else {
                    ForEach(Array(groups.enumerated()), id: \.offset) { section($0.element, step: $0.offset) }
                }
            }
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s3)
        }
        .scrollBounceBehavior(.basedOnSize)
        .canvas()
        .navigationTitle("Game Tools")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if running {
                ToolbarItem(placement: .topBarTrailing) { LiveMarker() }
            }
        }
        .navigationDestination(item: $open) { destination($0, capabilities: capabilities) }
        .onChange(of: open) { _, section in
            if let section {
                UserDefaults.standard.set(section.rawValue, forKey: lastSectionKey)
            }
        }
    }

    private static let groups: [Set<ToolsSection>] = [
        [.variables, .cheats, .renpyTools],
        [.persistentData, .saves, .mods, .translations],
        [.controls, .runtime, .diagnostics],
    ]

    private var lastSectionKey: String { "tools.lastSection.\(game.id.rawValue.uuidString)" }

    private func section(_ entries: [GameToolsCapabilities.Entry], step: Int) -> some View {
        GlassSection {
            ForEach(entries) { row($0) }
        }
        .frame(maxWidth: .infinity)
        .rise(1 + step)
    }

    /// Icon, title, one line saying what it holds (or why it is unavailable), chevron. Unavailable rows are grey
    /// and have no chevron.
    private func row(_ entry: GameToolsCapabilities.Entry) -> some View {
        let available = entry.availability == .available
        return Button { open = entry.section } label: {
            ListRow(
                icon: entry.section.symbol,
                title: entry.section.title,
                subtitle: entry.availability.reason ?? entry.section.subtitle,
                minHeight: 62,
                dimmed: !available
            ) {
                if available {
                    Chevron()
                }
            }
        }
        .buttonStyle(.row)
        .disabled(!available)
        .accessibilityHint(available ? "" : (entry.availability.reason ?? ""))
    }

    @ViewBuilder
    private func destination(_ section: ToolsSection, capabilities: GameToolsCapabilities) -> some View {
        switch section {
        case .variables:
            if let tools = model.tools {
                VariablesView(tools: tools, categories: capabilities.variableCategories, cheatsFor: game.id)
            }
        case .cheats:
            if let tools = model.tools {
                CheatsView(tools: tools, game: game)
            }
        case .renpyTools: RenPyToolsView(game: game, capabilities: capabilities, tools: model.tools)
        case .saves:
            if running, let tools = model.tools, let slots = tools.slots {
                InGameSavesView(
                    game: game, tools: tools, slots: slots,
                    variables: VariablesView(tools: tools, categories: capabilities.variableCategories)
                )
            } else {
                SaveBackupsView(game: game, running: model.playing?.id == game.id)
            }
        case .persistentData: PersistentDataView(game: game, running: running, tools: model.tools)
        case .diagnostics: DiagnosticsView(game: game, snapshot: snapshot)
        case .mods: ModsView(game: game, running: running)
        case .translations: TranslationsView(game: game, liveTranslation: capabilities.canLiveTranslate)
        case .runtime: RuntimePageView(game: game, snapshot: snapshot)
        case .controls: ControlsToolsView(game: game)
        }
    }
}

extension GameToolsCapabilities.Availability {
    var reason: String? {
        if case let .unavailable(reason) = self {
            reason
        } else {
            nil
        }
    }
}

extension ToolsSection {
    var title: String {
        switch self {
        case .variables: "Variables"
        case .cheats: "Cheats"
        case .renpyTools: "Ren'Py Tools"
        case .mods: "Mods"
        case .translations: "Translations"
        case .saves: "Saves and backups"
        case .persistentData: "Persistent data"
        case .controls: "Controls"
        case .runtime: "Runtime"
        case .diagnostics: "Diagnostics"
        }
    }

    var subtitle: String {
        switch self {
        case .variables: "Edit, watch and freeze values"
        case .cheats: "Ready-made changes you can undo"
        case .renpyTools: "Console and developer switches"
        case .mods: "Installed mods and load order"
        case .translations: "Translation packs"
        case .saves: "Slots, snapshots, import and export"
        case .persistentData: "Data the game keeps between saves"
        case .controls: "Touch and controller layout"
        case .runtime: "Engine and speed"
        case .diagnostics: "What OmniPlay found, and logs"
        }
    }

    var symbol: String {
        switch self {
        case .variables: "slider.horizontal.3"
        case .cheats: "sparkle"
        case .renpyTools: "terminal"
        case .mods: "puzzlepiece.extension"
        case .translations: "character.book.closed"
        case .saves: "clock"
        case .persistentData: "internaldrive"
        case .controls: "gamecontroller"
        case .runtime: "cpu"
        case .diagnostics: "stethoscope"
        }
    }
}

/// "Live": a small green dot that breathes while the game runs, the one pulsing mark in the app.
struct LiveMarker: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.success).frame(width: 7, height: 7)
                .phaseAnimator(reduceMotion ? [1.0] : [1.0, 0.35]) { dot, phase in dot.opacity(phase) } animation: { _ in
                    .easeInOut(duration: 1.1)
                }
            Text("Live").font(.footnote.weight(.medium)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, Theme.s2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live: the game is running and changes apply now")
    }
}
