import GameCore
import GameDetection
import GameStore
import GameTools
import RuntimeCore
import SwiftUI

/// What OmniPlay decided for this game and why: the engine and version detection found, how sure it is and the
/// evidence, the runtime chosen and the others that fit, the last automatic fallback, whether the engine's slot is
/// spent this launch, and the settings the runtime starts with. Automatic stays the default; choosing a runtime is
/// behind "Advanced".
struct RuntimePageView: View {
    @Environment(AppModel.self) private var model
    let game: GameRecord
    @State var snapshot: DetectionSnapshot?
    @State private var resolution: RuntimeResolution?
    @State private var advanced = false
    @State private var message: String?
    @State private var settings: [String: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s4) {
                if let snapshot {
                    card("Detected") {
                        row("Engine", snapshot.report.descriptor.engine.displayName)
                        if let version = snapshot.report.descriptor.version?.raw {
                            row("Version", version)
                        }
                        row("Confidence", snapshot.report.confidence.formatted(.percent.precision(.fractionLength(0))))
                        ForEach(snapshot.report.evidence.filter { $0.confidence >= 0.8 }.prefix(4), id: \.explanation) { evidence in
                            Text("• " + evidence.explanation).font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                if let resolution {
                    card("Runtime") {
                        row("Runs on", resolution.selectedRuntime.map(DetectionExplainer.name) ?? "None in this build")
                        row("Chosen", resolution.manualOverride ? "By you, for this game" : "Automatically")
                        if !resolution.manualOverride {
                            Text(resolution.reason).font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        if let slot = resolution.slot {
                            row("Engine this launch", model.spentSlots.contains(slot) ? "Used; restart OmniPlay to run it again" : "Free")
                        }
                        if !resolution.fallbacks.isEmpty {
                            row("Also fits", resolution.fallbacks.map { DetectionExplainer.name($0.runtime) }.joined(separator: ", "))
                        }
                    }
                    if let attempt = model.lastFallback(for: game.id) {
                        card("Last automatic fallback") {
                            row("From", DetectionExplainer.name(attempt.first))
                            row("To", DetectionExplainer.name(attempt.candidate))
                            row("Because", attempt.category.rawValue)
                            Text(attempt.result).font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    let settings = resolution.profile.overrides.filter { !$0.key.hasPrefix("renpy.") }.sorted { $0.key < $1.key }
                    if !settings.isEmpty {
                        card("Starts with") {
                            ForEach(settings, id: \.key) { key, value in
                                row(key, value.count > 60 ? String(value.prefix(57)) + "…" : value)
                            }
                        }
                    }
                }
                DisclosureGroup(isExpanded: $advanced) {
                    advancedChoices.padding(.top, Theme.s2)
                } label: {
                    Label("Advanced", systemImage: "slider.horizontal.3").font(.subheadline).foregroundStyle(Theme.textPrimary)
                }
                .tint(Theme.textSecondary)
                .padding(Theme.s4)
                .surface()
                if let message {
                    Text(message).font(.footnote).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s3)
        }
        .canvas()
        .navigationTitle("Runtime")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
    }

    private var advancedChoices: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Text(
                """
                Only for games that play wrong on the automatic choice. The choice applies to this game only and takes \
                effect at its next start.
                """
            )
            .font(.caption).foregroundStyle(Theme.textSecondary)
            if let report = snapshot?.report {
                ForEach(DetectionExplainer.candidates(report)) { choice in
                    Button { Task { await choose(choice.runtime) } } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(DetectionExplainer.name(choice.runtime)).foregroundStyle(Theme.textPrimary)
                                Text(choice.reason).font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            if resolution?.selectedRuntime == choice.runtime, resolution?.manualOverride == true {
                                Image(systemName: "checkmark").foregroundStyle(Theme.textPrimary)
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("Back to automatic choice") { Task { await choose(nil) } }
                .buttonStyle(.link)
                .disabled(resolution?.manualOverride != true)
            Button("Detect the engine again") { Task { await redetect() } }
                .buttonStyle(.link)
            let available = RuntimeSettings.available(for: resolution?.selectedRuntime, engine: snapshot?.report.descriptor.engine)
            if !available.isEmpty {
                Divider().padding(.vertical, Theme.s2)
                Text("Settings at start").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                ForEach(available) { setting in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(setting.title).font(.subheadline).foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Picker(setting.title, selection: binding(for: setting)) {
                                ForEach(setting.options, id: \.value) { Text($0.title).tag($0.value) }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .tint(Theme.textSecondary)
                        }
                        .frame(minHeight: 44)
                        Text(setting.detail).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }

    /// A section header over a glass group of facts, like the grouped lists elsewhere.
    private func card(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary).padding(.horizontal, Theme.s4)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(Theme.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .surface()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: Theme.s3)
            Text(value).foregroundStyle(Theme.textPrimary).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private func binding(for setting: RuntimeSetting) -> Binding<String> {
        Binding {
            settings[setting.key] ?? model.runtimeSetting(setting, for: game.id)
        } set: { value in
            settings[setting.key] = value
            model.setRuntimeSetting(setting, to: value, for: game.id)
            message = "\(setting.title) applies from the next start."
        }
    }

    private func reload() async {
        guard let snapshot, let record = try? model.store?.games.fetch(id: game.id) else { return }
        resolution = await model.freshResolution(for: record, snapshot: snapshot)
    }

    private func redetect() async {
        do {
            guard let fresh = try await model.redetect(game.id) else { return }
            snapshot = fresh
            resolution = fresh.resolution
            message = "Detected as \(fresh.report.descriptor.engine.displayName); applies from the next start."
        } catch {
            message = "Detection failed: \(error.localizedDescription)"
        }
    }

    private func choose(_ runtime: RuntimeIdentifier?) async {
        if let updated = await model.chooseRuntime(runtime, for: game.id) {
            resolution = updated
            message = runtime.map { "\(DetectionExplainer.name($0)) from the next start." } ?? "Back to the automatic choice."
        }
    }
}
