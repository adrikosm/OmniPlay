import GameImport
import SwiftUI

struct ImportView: View {
    private let limits = ImportLimits.default

    var body: some View {
        NavigationStack {
            List {
                Section("Import pipeline") {
                    Text("Transactional importer (libarchive + unrar + libmspack + PE/EVB/asar unwrap) is a Phase 0 deliverable.")
                        .foregroundStyle(.secondary)
                }
                Section("Safety limits (design authority §13.3)") {
                    LabeledContent("Max uncompressed", value: limits.maxUncompressedBytes.formatted(.byteCount(style: .binary)))
                    LabeledContent("Max entries", value: limits.maxEntries.formatted())
                    LabeledContent("Entry ratio", value: "\(Int(limits.maxEntryCompressionRatio)):1")
                    LabeledContent("Overall ratio", value: "\(Int(limits.maxOverallCompressionRatio)):1")
                    LabeledContent("Nested archives", value: limits.maxNestedArchives.formatted())
                }
            }
            .navigationTitle("Import")
        }
    }
}
