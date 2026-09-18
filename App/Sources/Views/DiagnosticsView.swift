import Diagnostics
import SwiftUI

struct DiagnosticsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Log categories (design authority §18)") {
                    ForEach(LogCategory.allCases, id: \.self) { category in
                        Text(category.rawValue)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                Section {
                    Text(
                        "Per-session export bundles, KSCrash reports and memory traces are Phase 0/4 deliverables. "
                            + "No telemetry, no network."
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Diagnostics")
        }
    }
}
