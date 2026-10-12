import GameTools
import RuntimeCore
import SwiftUI

/// The enemies of the battle in progress: each one's health, which can be set, and a button to defeat it at once or
/// bring it back at full health. A defeat is the game's own knockout, so the battle ends and pays out as usual.
struct EnemiesView: View {
    let tools: MutationEngine
    @State private var foes: [Foe] = []
    @State private var loaded = false
    @State private var problem: String?
    @State private var revision = 0
    @State private var working = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Foe: Identifiable, Hashable {
        let id: Int
        var name = ""
        var hp = 0
        var mhp = 0
        var alive = true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s4) {
                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(Theme.danger).padding(.horizontal, Theme.s4)
                }
                if foes.isEmpty {
                    if loaded {
                        ContentUnavailableView {
                            Label("No battle right now", systemImage: "figure.fencing")
                        } description: {
                            Text("Open this during a fight. Each enemy shows up here with its health.")
                        } actions: {
                            Button("Check again") { Task { await load() } }.buttonStyle(.link)
                        }
                        .padding(.top, Theme.s6)
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, Theme.s8)
                    }
                } else {
                    HStack(spacing: Theme.s2) {
                        Button("Defeat all") { Task { await setAll(alive: false) } }
                            .buttonStyle(PillButtonStyle(kind: .primary, height: 44))
                            .disabled(working || foes.allSatisfy { !$0.alive })
                        Button("Restore all") { Task { await setAll(alive: true) } }
                            .buttonStyle(PillButtonStyle(kind: .secondary, height: 44))
                            .disabled(working || foes.allSatisfy { $0.alive && $0.hp == $0.mhp })
                    }
                    .rise(0)
                    GlassSection(footer: "Changes show in the battle when you go back to the game. Undo is in Variables.") {
                        ForEach(foes) { foe in
                            card(foe)
                        }
                    }
                    .rise(1)
                }
            }
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s3)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .canvas()
        .navigationTitle("Enemies")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
                    .symbolEffect(.rotate, value: revision)
                    .tint(Theme.textPrimary)
            }
        }
        .task { await load() }
    }

    /// Name, a health bar, then the health itself (− value +, tap to type) and Defeat or Restore.
    private func card(_ foe: Foe) -> some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack(alignment: .firstTextBaseline) {
                Text(foe.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: Theme.s2)
                Text(foe.alive ? "\(foe.hp.formatted()) / \(foe.mhp.formatted()) HP" : "Defeated")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(foe.alive ? Theme.textSecondary : Theme.danger)
                    .contentTransition(.numericText())
            }
            HealthBar(fraction: foe.mhp > 0 ? Double(foe.hp) / Double(foe.mhp) : 0)
            HStack(spacing: Theme.s2) {
                CheatRow(
                    title: "Health", detail: nil, target: .enemy(index: foe.id, .hp), seed: .int(foe.hp), tools: tools,
                    revision: revision, onValue: { _ in }, onApplied: { Task { await load() } }
                )
                .padding(.horizontal, -14)
                Button(foe.alive ? "Defeat" : "Restore") { Task { await set(foe, alive: !foe.alive) } }
                    .buttonStyle(PillButtonStyle(kind: foe.alive ? .destructive : .secondary, height: 34))
                    .frame(minHeight: 44)
                    .disabled(working)
            }
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s3)
        .animation(Theme.motion(Theme.snap, reduce: reduceMotion), value: foe)
    }

    private func set(_ foe: Foe, alive: Bool) async {
        working = true
        defer { working = false }
        let result = await tools.apply(.setValue(.bool(alive)), to: .enemy(index: foe.id, .alive))
        problem = result.result == .rejected ? result.validation.first?.message ?? "The game refused the change." : nil
        await load()
    }

    private func setAll(alive: Bool) async {
        working = true
        defer { working = false }
        for foe in foes where foe.alive != alive || (alive && foe.hp < foe.mhp) {
            let result = await tools.apply(.setValue(.bool(alive)), to: .enemy(index: foe.id, .alive))
            if result.result == .rejected {
                problem = result.validation.first?.message ?? "The game refused the change."
                break
            }
        }
        await load()
    }

    private func load() async {
        do {
            let page = try await tools.list(.enemies, query: nil, page: StatePage(size: 1000))
            var byIndex: [Int: Foe] = [:]
            for entry in page.entries {
                guard case let .enemy(index, property) = entry.target else { continue }
                var foe = byIndex[index] ?? Foe(id: index)
                foe.name = entry.name
                switch (property, entry.value) {
                case let (.hp, .int(n)): foe.hp = n
                case let (.mhp, .int(n)): foe.mhp = n
                case let (.alive, .bool(on)): foe.alive = on
                default: break
                }
                byIndex[index] = foe
            }
            foes = byIndex.values.sorted { $0.id < $1.id }
            problem = nil
        } catch StateBridgeError.notInGame {
            foes = []
        } catch {
            problem = "The enemies could not be read: \(error)"
        }
        loaded = true
        revision += 1
    }
}

/// Health as a thin bar: light while healthy, red under a quarter.
private struct HealthBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.fill)
                Capsule()
                    .fill(fraction < 0.25 ? Theme.danger : Theme.textPrimary.opacity(0.8))
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}
