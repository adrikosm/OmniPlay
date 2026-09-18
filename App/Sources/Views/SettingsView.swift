import Diagnostics
import GameCore
import SwiftUI

struct SettingsView: View {
    @State private var footprint: UInt64 = 0
    @State private var freeSpace: Int64?

    private var session: HostSession { HostSession.shared }

    var body: some View {
        NavigationStack {
            List {
                Section("Storage") {
                    Text(session.paths.root.path(percentEncoded: false))
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    LabeledContent("Free space", value: freeSpace.map { $0.formatted(.byteCount(style: .file)) } ?? "unknown")
                }
                Section("Memory") {
                    LabeledContent("Footprint", value: Int64(footprint).formatted(.byteCount(style: .memory)))
                    Button("Sample now") { refresh(label: "manual") }
                }
                Section("Session slots") {
                    ForEach(SessionSlot.allCases, id: \.self) { slot in
                        LabeledContent(slot.rawValue, value: slot.sessionsPerProcess.rawValue)
                    }
                }
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                    LabeledContent("Session", value: session.sessionID.description)
                        .font(.footnote)
                }
            }
            .navigationTitle("Settings")
            .onAppear { refresh(label: "settings") }
        }
    }

    private func refresh(label: String) {
        footprint = MemoryProbe.footprint
        session.recordMemory(label: label)
        freeSpace = try? session.paths.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }
}
