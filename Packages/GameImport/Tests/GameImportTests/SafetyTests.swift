import Foundation
@testable import GameCore
import GameImport
import Testing
import TestSupport

@Suite("Archive extraction and safety", .serialized)
struct SafetyTests {
    let extractor = LibArchiveExtractor()

    private struct Extracted { let out: URL, totals: RunningTotals, root: TemporaryGameRoot }
    private func extract(_ fixture: String, hdrcharset: String? = nil) throws -> Extracted {
        let root = try TemporaryGameRoot(name: "x")
        let out = root.url.appending(path: "out")
        let totals = try extractor.extract(Fixtures.url(fixture), to: out, hdrcharset: hdrcharset)
        return Extracted(out: out, totals: totals, root: root)
    }

    /// The extraction trust boundary: anything an untrusted archive could use to write outside the
    /// staging tree, or to fill the disk, fails here before a byte lands.
    @Test("Traversal, absolute paths and symlinks never escape staging; a bomb stops on ratio")
    func safety() async throws {
        for fixture in ["traversal.zip", "absolute.zip"] {
            do {
                _ = try extract(fixture)
                Issue.record("\(fixture) extracted")
            } catch let v as SafetyViolation {
                #expect(v.rule == .invalidPath, Comment(rawValue: fixture))
            } catch { Issue.record("\(fixture): \(error)") }
        }
        // A file name with NEL or LINE SEPARATOR would split the seal manifest's lines.
        for name in ["a\u{2028}b.txt", "c\u{85}d.txt"] {
            #expect(throws: ImportPathError.controlCharacter) { try ImportPathValidator().validate(name) }
        }

        // ZIP64 sizes near 2^62 (153 bytes on disk) are refused at the header, before the disk budget's sums overflow.
        let zip64Root = try TemporaryGameRoot(name: "zip64")
        defer { zip64Root.remove() }
        let zip64 = try zip64Root.file("huge.zip", #require(Data(base64Encoded: Self.zip64Huge)))
        #expect { try extractor.preflight(zip64) } throws: { ($0 as? SafetyViolation)?.rule == .declaredSize }
        #expect { try extractor.extract(zip64, to: zip64Root.url.appending(path: "out")) } throws: {
            ($0 as? SafetyViolation)?.rule == .declaredSize
        }
        #expect(StorageBudget.needed(for: .forArchive(uncompressedSizeHint: 1 << 62)) == .max)

        /// ASAR headers are parsed whole by Foundation: one over 16 MiB is refused unread, and a tree past the entry cap
        /// stops at the cap instead of being copied out first.
        func asar(_ json: String, declared: Int? = nil) -> Data {
            let n = json.utf8.count, header = declared ?? n
            return [4, header + 8, header + 4, header].reduce(into: Data()) { out, word in
                withUnsafeBytes(of: UInt32(word).littleEndian) { out.append(contentsOf: $0) }
            } + Data(json.utf8)
        }
        let bigHeader = try zip64Root.file("big.asar", asar("{}", declared: 17 << 20))
        #expect(throws: ImportFailure.self) { try AsarExtractor.header(of: bigHeader) }
        let nodes = (0 ..< 5).map { "\"f\($0)\":{\"size\":0,\"offset\":\"0\"}" }.joined(separator: ",")
        let crowded = try zip64Root.file("crowded.asar", asar("{\"files\":{\(nodes)}}"))
        var fewEntries = SafetyLimits.default
        fewEntries.maxEntries = 2
        #expect { try AsarExtractor(limits: fewEntries).extract(crowded, to: zip64Root.url.appending(path: "asar")) } throws: {
            ($0 as? SafetyViolation)?.rule == .entryCount
        }

        // RPG Maker installers carry cabinets, which libmspack decodes; their names go through the same validator.
        let cabRoot = try TemporaryGameRoot(name: "cab")
        defer { cabRoot.remove() }
        let cab = cabRoot.url.appending(path: "traversal.cab")
        try cabinet(name: "../escape.txt", payload: Data("out".utf8)).write(to: cab)
        #expect { try CabExtractor().extract(cab, to: cabRoot.url.appending(path: "out")) } throws: {
            ($0 as? SafetyViolation)?.rule == .invalidPath
        }
        #expect(!FileManager.default.fileExists(atPath: cabRoot.url.appending(path: "escape.txt").path(percentEncoded: false)))

        let x = try extract("symlink.tar")
        defer { x.root.remove() }
        let link = x.out.appending(path: "link")
        #expect((try? link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true)
        #expect(try Data(contentsOf: link.appending(path: "inner.txt")) == Data("trap\n".utf8))
        #expect(x.totals.skipped == 1)
        _ = try PostExtractionAudit.run(root: x.out, totals: x.totals, sourceBytes: nil)

        let bombRoot = try TemporaryGameRoot(name: "bomb")
        defer { bombRoot.remove() }
        let start = Date.now
        var caught: SafetyViolation?
        let growth = try await MemoryAssert.footprintGrowth {
            do { _ = try extractor.extract(Fixtures.url("bomb-ratio.zip"), to: bombRoot.url.appending(path: "out"))
            } catch let v as SafetyViolation { caught = v }
        }
        #expect(caught?.rule == .overallRatio)
        #expect(Date.now.timeIntervalSince(start) < 5)
        #expect(growth < 64 << 20, "footprint grew by \(growth >> 20) MiB")

        // RGSS archives are parsed by the engine in process; a damaged one is refused before it mounts. The XP stub
        // is a truncated download: a valid header, then a name length far past mkxp-z's 512-byte buffer.
        for fixture in ["rgss-xp/Game.rgssad", "rgss-vxace/Game.rgss3a"] {
            #expect(throws: RGSSArchive.Invalid.self, Comment(rawValue: fixture)) { try RGSSArchive.validate(Fixtures.url(fixture)) }
        }
        let good = bombRoot.url.appending(path: "Game.rgssad")
        try rgssad([("Data\\Scripts.rxdata", Data(count: 40)), ("Graphics\\Titles\\Title.png", Data(count: 7))]).write(to: good)
        #expect(try RGSSArchive.validate(good) == 2)

        // Shipped bug: a wrapper with loose files (the official MZ sample: launcher, readme, `gamedata/`) got its root
        // reported relative to the wrapper, so the import pointed at a folder that did not exist.
        let wrapped = bombRoot.url.appending(path: "staged")
        let game = wrapped.appending(path: "SoulsLore/gamedata")
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        for file in [
            game.appending(path: "index.html"),
            wrapped.appending(path: "SoulsLore/Game.exe"),
            wrapped.appending(path: "SoulsLore/readme.txt"),
        ] {
            try Data().write(to: file)
        }
        #expect(try GameRootLocator.locate(stagingRoot: wrapped).relativePath == "SoulsLore/gamedata")
    }

    /// One stored entry `a.bin` whose ZIP64 extra field declares 2^62 bytes (it holds five).
    private static let zip64Huge = "UEsDBC0AAAAAAAAAAACGphA2//////////8FABQAYS5iaW4BABAAAAAAAAAAAEAFAAAAAAAAAGhlbGxv"
        + "UEsBAi0ALQAAAAAAAAAAAIamEDb//////////wUAFAAAAAAAAAAAAAAAAAAAAGEuYmluAQAQAAAAAAAAAABABQAAAAAAAABQSwUGAAAAAAEAAQBH"
        + "AAAAPAAAAAAA"

    /// A one-file, uncompressed Microsoft cabinet (MS-CAB: header, folder, file, one data block without checksum).
    private func cabinet(name: String, payload: Data) -> Data {
        var out = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { out.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { out.append(contentsOf: $0) } }
        let fileEntry = 16 + name.utf8.count + 1
        let dataStart = 36 + 8 + fileEntry
        out.append(contentsOf: "MSCF".utf8)
        u32(0); u32(dataStart + 8 + payload.count); u32(0); u32(36 + 8); u32(0)
        out.append(contentsOf: [3, 1]) // version 1.3
        u16(1); u16(1); u16(0); u16(0); u16(0) // folders, files, flags, set id, cabinet index
        u32(dataStart); u16(1); u16(0) // folder: first data block, one block, no compression
        u32(payload.count); u32(0); u16(0); u16(0x5821); u16(0); u16(0x20) // file: size, offset, folder, date, time, attribs
        out.append(contentsOf: name.utf8); out.append(0)
        u32(0); u16(payload.count); u16(payload.count) // data block: no checksum
        out.append(payload)
        return out
    }

    /// A version 1 archive as RPG Maker XP writes it (the payload stays unencrypted; only the table matters here).
    private func rgssad(_ files: [(String, Data)]) -> Data {
        var out = Data("RGSSAD\0\u{1}".utf8)
        var key: UInt32 = 0xDEAD_CAFE
        func next() -> UInt32 {
            defer { key = key &* 7 &+ 3 }
            return key
        }
        func word(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        for (name, payload) in files {
            word(UInt32(name.utf8.count) ^ next())
            for byte in name.utf8 {
                out.append(byte ^ UInt8(truncatingIfNeeded: next()))
            }
            word(UInt32(payload.count) ^ next())
            out.append(payload)
        }
        return out
    }
}
