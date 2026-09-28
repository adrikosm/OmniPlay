import GameStore
import GameTools
import RuntimeCore
import SwiftUI

extension RenPyToolsView {
    // MARK: Script inserts

    var insertsList: some View {
        GlassSection(
            "Script inserts",
            footer: "Your own Ren'Py code, added at the next launch as a mod the game's files never see. Python runs at the end of "
                + "init; statements (label, define, screen…) are kept as written. An insert Ren'Py cannot load is switched off."
        ) {
            TextField("Name", text: $insertName)
                .font(.subheadline).foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, Theme.s4).frame(minHeight: 46)
            TextField("config.developer = True", text: $insertCode, axis: .vertical)
                .font(Theme.mono).foregroundStyle(Theme.textPrimary)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .lineLimit(2 ... 8)
                .padding(.horizontal, Theme.s4).padding(.vertical, Theme.s3)
                .accessibilityLabel("Insert code")
            HStack {
                if let insertMessage {
                    Text(insertMessage).font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("Add insert") { Task { await addInsert() } }
                    .buttonStyle(.link)
                    .disabled(insertName.trimmingCharacters(in: .whitespaces).isEmpty
                        || insertCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, Theme.s4)
            ForEach(inserts) { insert in
                ListRow(
                    title: insert.name,
                    subtitle: model.insertError(insert).flatMap { insert.enabled ? nil : "Switched off after this error: " + $0 }
                ) {
                    Toggle(insert.name, isOn: Binding(get: { insert.enabled }, set: { on in
                        Task {
                            await model.setModEnabled(insert, on)
                            reloadInserts()
                        }
                    }))
                    .labelsHidden()
                }
            }
        }
    }

    func reloadInserts() {
        inserts = model.mods(for: game.id).filter { $0.source == AppModel.insertSource }
    }

    func addInsert() async {
        do {
            let record = try await model.installInsert(named: insertName, code: insertCode, for: game)
            insertMessage = "\(record.name) is added; it runs from the next launch."
            insertName = ""
            insertCode = ""
        } catch {
            insertMessage = "Not added: \(error.localizedDescription)"
        }
        reloadInserts()
    }

    // MARK: Developer switches

    struct SwitchInfo {
        let name, title, detail: String
        init(_ name: String, _ title: String, _ detail: String) { (self.name, self.title, self.detail) = (name, title, detail) }
    }

    static let switchInfo: [SwitchInfo] = [
        SwitchInfo("developer", "Developer mode", "Ren'Py's developer menu and inspectors (Shift+D with a keyboard)."),
        SwitchInfo("console", "Built-in console", "Ren'Py's own console (Shift+O with a keyboard)."),
        SwitchInfo("rollback", "Rollback", "Rolling back works even where the game turned it off, up to 256 steps."),
        SwitchInfo("skipUnseen", "Skip unseen text", "Skipping also passes text you have not read yet."),
        SwitchInfo("skipSplash", "Skip the splash screen", "Starts at the main menu."),
    ]

    var switchesList: some View {
        GlassSection("Developer switches", footer: "These take effect the next time the game starts.") {
            ForEach(Self.switchInfo, id: \.name) { info in
                ListRow(title: info.title, subtitle: info.detail, minHeight: 62) {
                    Toggle(info.title, isOn: Binding(get: { switches[info.name] ?? false }, set: { on in
                        switches[info.name] = on
                        model.setDeveloperSwitch(info.name, on, for: game.id)
                    }))
                    .labelsHidden()
                }
            }
        }
    }
}
