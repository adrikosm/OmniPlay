import Diagnostics
import SwiftUI

struct DiagnosticsView: View {
    @State private var bundleURL: URL?
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Host session") {
                    Text(HostSession.shared.directory.path(percentEncoded: false))
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Prepare log bundle") {
                        do { bundleURL = try HostSession.shared.exportBundle() } catch { exportError = error.localizedDescription }
                    }
                    if let bundleURL {
                        ShareLink(item: bundleURL) { Label("Share log bundle", systemImage: "square.and.arrow.up") }
                    }
                    if let exportError {
                        Text(exportError).foregroundStyle(.red)
                    }
                }
                Section("Log categories") {
                    ForEach(LogCategory.allCases, id: \.self) { category in
                        Text(category.rawValue).font(.system(.body, design: .monospaced))
                    }
                }
            }
            .navigationTitle("Diagnostics")
        }
    }
}
