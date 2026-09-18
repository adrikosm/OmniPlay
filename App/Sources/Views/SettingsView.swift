import GameCore
import RuntimeCore
import SwiftUI

struct SettingsView: View {
    private var storageRoot: String {
        (try? StorageLayout.applicationDefault().root.path(percentEncoded: false)) ?? "unavailable"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Storage (design authority §15.2)") {
                    Text(storageRoot)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
                Section("Session slots (design authority §14.2)") {
                    ForEach(SessionSlot.allCases, id: \.self) { slot in
                        LabeledContent(slot.rawValue, value: slot.capacity.summary)
                    }
                }
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.shortVersion)
                    LabeledContent("Build", value: Bundle.main.buildNumber)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

private extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "—" }
    var buildNumber: String { infoDictionary?["CFBundleVersion"] as? String ?? "—" }
}

private extension SlotCapacity {
    var summary: String {
        switch self {
        case .unlimited: "unlimited"
        case .one: "1 per launch"
        case .unlimitedUnverified: "1 per launch (until verified)"
        }
    }
}
