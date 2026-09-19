import Foundation
import GameCore
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

    @Test("A plain ZIP extracts byte-identical to the fixture tree")
    func zipRoundTrip() throws {
        let x = try extract("mv-basic.zip")
        let (out, totals, root) = (x.out, x.totals, x.root)
        defer { root.remove() }
        var files = 0
        try LazyDirectoryWalker.walk(root: Fixtures.url("mv-basic")) { e in
            if !e.isDirectory {
                files += 1
                let got = try Data(contentsOf: out.appending(path: "mv-basic/\(e.relativePath)"))
                let want = try Data(contentsOf: e.url)
                #expect(got == want, Comment(rawValue: e.relativePath))
            }
            return .continue
        }
        #expect(files > 10)
        let audited = try PostExtractionAudit.run(root: out, totals: totals, sourceBytes: 1)
        #expect(audited.writtenBytes == totals.writtenBytes)
        let pre = try extractor.preflight(Fixtures.url("mv-basic.zip"))
        #expect(pre.entries == totals.entries && pre.declaredBytes == totals.writtenBytes && !pre.encrypted && !pre.undecodableNames)
    }

    @Test("Traversal and absolute entries are rejected before any write")
    func traversalAndAbsolute() {
        for fixture in ["traversal.zip", "absolute.zip"] {
            do {
                _ = try extract(fixture)
                Issue.record("\(fixture) extracted")
            } catch let v as SafetyViolation {
                #expect(v.rule == .invalidPath, Comment(rawValue: fixture))
            } catch { Issue.record("\(fixture): \(error)") }
        }
    }

    @Test("Symlinks are never materialised; files under a link path land in a real directory")
    func symlinks() throws {
        let x = try extract("symlink.tar")
        let (out, totals, root) = (x.out, x.totals, x.root)
        defer { root.remove() }
        let link = out.appending(path: "link")
        #expect((try? link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true)
        let inner = try Data(contentsOf: link.appending(path: "inner.txt"))
        #expect(inner == Data("trap\n".utf8))
        #expect(totals.skipped == 1)
        _ = try PostExtractionAudit.run(root: out, totals: totals, sourceBytes: nil)
    }

    @Test("A compression bomb is stopped by the overall ratio within seconds and bounded memory")
    func bomb() async throws {
        let root = try TemporaryGameRoot(name: "bomb")
        defer { root.remove() }
        let start = Date.now
        var caught: SafetyViolation?
        let growth = try await MemoryAssert.footprintGrowth {
            do { _ = try extractor.extract(Fixtures.url("bomb-ratio.zip"), to: root.url.appending(path: "out"))
            } catch let v as SafetyViolation { caught = v }
        }
        #expect(caught?.rule == .overallRatio)
        #expect(Date.now.timeIntervalSince(start) < 5)
        #expect(growth < 64 << 20, "footprint grew by \(growth >> 20) MiB")
    }

    @Test("A truncated archive fails with a named extraction error")
    func corrupt() {
        do { _ = try extract("corrupt.zip"); Issue.record("corrupt zip extracted") } catch is ExtractionError {} catch {
            Issue.record("\(error)")
        }
    }

    @Test("CP932 names decode when the header charset is given")
    func shiftJIS() throws {
        let pre = try extractor.preflight(Fixtures.url("shiftjis-names.zip"))
        #expect(pre.undecodableNames || pre.entries == 2)
        let x = try extract("shiftjis-names.zip", hdrcharset: "CP932")
        let (out, root) = (x.out, x.root)
        defer { root.remove() }
        #expect(FileManager.default.fileExists(atPath: out.appending(path: "ゲーム/読んで.txt").path(percentEncoded: false)))
    }

    @Test("Nested zip entries come out as files for the pipeline's depth check")
    func nested() throws {
        let x = try extract("mv-basic-nested.zip")
        let (out, root) = (x.out, x.root)
        defer { root.remove() }
        #expect(try ContainerSniffer.identify(out.appending(path: "inner/mv-basic.zip")) == .zip)
        let v = EntryValidator()
        #expect(v.checkNesting(depth: 3) != nil && v.checkNesting(depth: 2) == nil)
    }

    @Test("Entry-count and declared-size bombs are caught from synthetic headers")
    func headerBombs() {
        var limits = SafetyLimits()
        limits.maxEntries = 10
        let v = EntryValidator(limits: limits)
        var t = RunningTotals()
        var lastRule: SafetyViolation.Rule?
        for i in 0 ..< 12 {
            if case let .reject(x) = v.validate(.init(path: "f\(i)"), running: &t) {
                lastRule = x.rule
            }
        }
        #expect(lastRule == .entryCount)
        var t2 = RunningTotals()
        if case let .reject(x) = v.validate(.init(path: "huge", declaredSize: Int64(limits.maxUncompressedBytes) + 1), running: &t2) {
            #expect(x.rule == .declaredSize)
        } else {
            Issue.record("declared size accepted")
        }
    }

    @Test("Disk precheck refuses an archive whose declared size cannot fit")
    func diskPrecheck() {
        let verdict = StorageBudget.check(.forArchive(uncompressedSizeHint: .max / 4), at: FileManager.default.temporaryDirectory)
        #expect(verdict.isBlocking)
    }

    #if os(macOS)
        @Test("7z, tar.gz, tar.xz and tar.zst made with bsdtar extract", arguments: ["7z", "tgz", "txz", "tzst"])
        func otherFormats(kind: String) throws {
            let root = try TemporaryGameRoot(name: "fmt")
            defer { root.remove() }
            let archive = root.url.appending(path: "a.\(kind)")
            let flags: [String] = switch kind {
            case "7z": ["--format", "7zip", "-cf"]
            case "tgz": ["-czf"]
            case "txz": ["-cJf"]
            default: ["--zstd", "-cf"]
            }
            let p = Process()
            p.executableURL = URL(filePath: "/usr/bin/tar")
            p.currentDirectoryURL = Fixtures.url("")
            p.arguments = flags + [archive.path(percentEncoded: false), "mz-basic"]
            try p.run(); p.waitUntilExit()
            #expect(p.terminationStatus == 0)
            let out = root.url.appending(path: "out")
            let totals = try extractor.extract(archive, to: out)
            #expect(totals.entries > 5)
            let got = try Data(contentsOf: out.appending(path: "mz-basic/js/rmmz_core.js"))
            let want = try Data(contentsOf: Fixtures.url("mz-basic/js/rmmz_core.js"))
            #expect(got == want)
        }
    #endif
}
