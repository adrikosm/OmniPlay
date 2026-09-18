import Foundation
import GameDetection

/// Synthetic tree for signature tests. No real game content is ever committed (Fixtures/README.md).
struct InMemoryGameTree: GameTreeProbe {
    var files: [String: Data]

    var paths: [String] { Array(files.keys) }

    func readPrefix(of relativePath: String, maxBytes: Int) throws -> Data? {
        files[relativePath].map { Data($0.prefix(maxBytes)) }
    }
}
