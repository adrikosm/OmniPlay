import Foundation
import InputKit
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
    @State private var showTools = false
    @Environment(AppModel.self) private var model
    /// The row a controller's D-pad is on; nil until a controller is used, so touch never shows a ring.
    @State private var focus: Item?

    /// What a controller can reach: up and down move through these, A presses, B or Options resumes.
    enum Item: Hashable { case resume, screenshot, tools, controls, engineMenu, logs, leave }

    private var items: [Item] {
        [.resume, .screenshot] + (gameTools == nil ? [] : [.tools]) + (hasTouchControls ? [.controls] : [])
            + (engineMenu == nil ? [] : [.engineMenu]) + [.logs, .leave]
    }

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
            .navigationDestination(isPresented: $showTools) { gameTools }
            // Only while the menu itself is on screen: a pushed page (the controller mapping screen) takes buttons.
            .onAppear { model.controllerListener = { controller($0) } }
            .onDisappear { model.controllerListener = nil }
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

    /// D-pad up/down moves the ring, A presses the ringed row, B or Options resumes. With the Leave question up, A
    /// leaves and B keeps playing.
    private func controller(_ button: ControllerButton) {
        if confirmExit {
            switch button {
            case .a: confirmExit = false; close(then: onExit)
            case .b, .options: confirmExit = false
            default: break
            }
            return
        }
        switch button {
        case .dpadDown, .dpadUp:
            let index = focus.flatMap { items.firstIndex(of: $0) } ?? (button == .dpadDown ? -1 : items.count)
            focus = items[min(max(index + (button == .dpadDown ? 1 : -1), 0), items.count - 1)]
        case .a: press(focus ?? .resume)
        case .b, .options: close(then: onResume)
        default: break
        }
    }

    private func press(_ item: Item) {
        switch item {
        case .resume: close(then: onResume)
        case .screenshot: takeScreenshot()
        case .tools: showTools = true
        case .controls: close(then: onEditControls)
        case .engineMenu: close(then: onEngineMenu)
        case .logs: showLogs = true
        case .leave: confirmExit = true
        }
    }

    private func takeScreenshot() {
        takingScreenshot = true
        Task {
            screenshotResult = await onScreenshot()
            takingScreenshot = false
        }
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
                    .ring(focus == .resume, radius: 26)
                Button { takeScreenshot() } label: {
                    Image(systemName: takingScreenshot ? "hourglass" : "camera").contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.round(52))
                .disabled(takingScreenshot)
                .accessibilityLabel("Take a screenshot")
                .ring(focus == .screenshot, radius: 26)
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
                    Button { showTools = true } label: {
                        ListRow(icon: "slider.horizontal.3", title: "Game Tools", minHeight: 44) { Chevron() }
                    }
                    .buttonStyle(.row)
                    .ring(focus == .tools)
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
                    .ring(focus == .controls)
                }
                if let engineMenu {
                    Button { close(then: onEngineMenu) } label: {
                        ListRow(icon: "list.bullet.rectangle", title: engineMenu, minHeight: 44) { Chevron() }
                    }
                    .buttonStyle(.row)
                    .ring(focus == .engineMenu)
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
                .ring(focus == .logs)
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
                .ring(focus == .leave)
            }
        }
    }
}

private extension View {
    /// The controller's focus ring: the accent outline around the row the D-pad is on.
    func ring(_ on: Bool, radius: CGFloat = 10) -> some View {
        overlay {
            if on {
                RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.accent, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }
}
