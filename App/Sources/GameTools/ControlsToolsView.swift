import GameStore
import InputKit
import SwiftUI

/// Game Tools → Controls (INPUT-007): which key each controller button sends in this game, and where its touch layout
/// came from. While playing, "Find a button" lights up the row of the next button pressed, so a player can map
/// without knowing the names. Options always opens OmniPlay's menu; Home belongs to the system.
struct ControlsToolsView: View {
    @Environment(AppModel.self) private var model
    let game: GameRecord
    @State private var mapping = InputMapping.rpgMaker
    @State private var layouts: ControlsLayoutSet?
    @State private var finding = false
    @State private var found: ControllerButton?

    var body: some View {
        ScrollView {
            Split(spacing: Theme.s6) {
                controller.rise(0)
            } trailing: {
                touchLayout.rise(1)
            }
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s3)
        }
        .canvas()
        .navigationTitle("Controls")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            mapping = model.controllerMapping(for: game.id)
            layouts = model.controlsLayouts(for: game.id)
        }
        .onDisappear { stopFinding() }
    }

    private var controller: some View {
        GlassSection(
            "Controller",
            footer: finding ? "Press a button on the controller." : "Options opens OmniPlay's menu. The stick moves like the D-pad.",
            trailing: findButton
        ) {
            ForEach(InputMapping.mappable, id: \.self) { button in
                Menu {
                    Button("Nothing") { assign(nil, to: button) }
                    ForEach(KeyCatalog.groups) { group in
                        Menu(group.title) {
                            ForEach(group.keys, id: \.key.rawValue) { entry in
                                Button(entry.name) { assign(entry.key, to: button) }
                            }
                        }
                    }
                } label: {
                    ListRow(title: Self.name(button)) {
                        HStack(spacing: Theme.s1) {
                            RowValue(text: mapping.keys(for: button).first.map(KeyCatalog.label) ?? "Nothing")
                            Chevron()
                        }
                    }
                    .background(found == button ? Theme.fill : .clear)
                }
                .accessibilityLabel("\(Self.name(button)) sends \(mapping.keys(for: button).first.map(KeyCatalog.label) ?? "nothing")")
            }
            Button("Back to the defaults") {
                model.setControllerMapping(nil, for: game.id)
                mapping = .rpgMaker
            }
            .buttonStyle(.link)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.s4)
            .disabled(mapping == .rpgMaker)
        }
    }

    @ViewBuilder private var findButton: some View {
        if model.activeCapture != nil {
            Button(finding ? "Stop" : "Find a button") { finding ? stopFinding() : startFinding() }.buttonStyle(.link)
        }
    }

    private var touchLayout: some View {
        GlassSection("Touch layout", footer: "Change it while playing: tap the controller icon, or Controls in the pause menu.") {
            ListRow(title: "In use") { RowValue(text: Self.source(layouts?.source)) }
            Button("Use the built-in layout") {
                // Clearing the game's own layout brings back its engine's default at the next start.
                model.setControlsLayouts(nil, for: game.id)
                layouts = model.controlsLayouts(for: game.id)
            }
            .buttonStyle(.link)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.s4)
            .disabled(layouts == nil || layouts?.source == "builtin")
        }
    }

    private func assign(_ key: GameKey?, to button: ControllerButton) {
        mapping.buttons[button] = key.map { [$0] } ?? []
        model.setControllerMapping(mapping, for: game.id)
    }

    private func startFinding() {
        finding = true
        found = nil
        model.controllerListener = { button in found = button }
    }

    private func stopFinding() {
        finding = false
        model.controllerListener = nil
    }

    static func name(_ button: ControllerButton) -> String {
        switch button {
        case .a: "A"
        case .b: "B"
        case .x: "X"
        case .y: "Y"
        case .leftShoulder: "Left shoulder (L1)"
        case .rightShoulder: "Right shoulder (R1)"
        case .leftTrigger: "Left trigger (L2)"
        case .rightTrigger: "Right trigger (R2)"
        case .dpadUp: "D-pad up"
        case .dpadDown: "D-pad down"
        case .dpadLeft: "D-pad left"
        case .dpadRight: "D-pad right"
        case .menu: "Menu"
        case .options: "Options"
        case .home: "Home"
        case .leftThumbstickButton: "Left stick press (L3)"
        case .rightThumbstickButton: "Right stick press (R3)"
        }
    }

    static func source(_ source: String?) -> String {
        switch source {
        case nil, "builtin": "Built in"
        case "joiplay": "From the JoiPlay package"
        case "kirin": "From the Kirin package"
        default: "Yours"
        }
    }
}
