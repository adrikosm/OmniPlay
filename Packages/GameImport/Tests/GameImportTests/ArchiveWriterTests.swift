import Foundation
import GameCore
import GameImport
import Testing
import TestSupport

@Suite("Archive writer")
struct ArchiveWriterTests {
    @Test("A directory zips with a manifest member and extracts back byte-identical")
    func roundTrip() throws {
        let root = try TemporaryGameRoot(name: "zipw")
        defer { root.remove() }
        let source = root.url.appending(path: "saves")
        try FileManager.default.createDirectory(at: source.appending(path: "slots"), withIntermediateDirectories: true)
        let big = Data((0 ..< (3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try big.write(to: source.appending(path: "slots/file1.rpgsave"))
        try Data("cfg".utf8).write(to: source.appending(path: "persistent.json"))
        let zip = root.url.appending(path: "out.zip")
        let count = try ArchiveWriter().zip(
            directory: source,
            to: zip,
            prefix: "Saves",
            extras: [("omniplay-save-manifest.json", Data("{}".utf8))]
        )
        #expect(count == 3)
        let out = root.url.appending(path: "back")
        let totals = try LibArchiveExtractor().extract(zip, to: out)
        #expect(totals.entries == 3)
        #expect(try Data(contentsOf: out.appending(path: "Saves/slots/file1.rpgsave")) == big)
        #expect(try Data(contentsOf: out.appending(path: "Saves/omniplay-save-manifest.json")) == Data("{}".utf8))
        let zipSize = try zip.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        #expect(zipSize > 0 && zipSize < big.count, "deflate should shrink the patterned data (\(zipSize))")
    }
}
