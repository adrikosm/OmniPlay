import Foundation
import GameCore
import GameImport
import Testing
import TestSupport

@Suite("Import transaction")
struct ImportTransactionTests {
    private func paths() throws -> (AppPaths, TemporaryGameRoot) {
        let root = try TemporaryGameRoot(name: "import")
        let p = AppPaths(
            root: root.url.appending(path: "S"),
            cachesRoot: root.url.appending(path: "C"),
            exportsRoot: root.url.appending(path: "E")
        )
        try p.ensureLayout()
        return (p, root)
    }

    @Test("A mocked pipeline visits every state in order and ends ready")
    func stateSequence() async throws {
        let (p, root) = try paths()
        defer { root.remove() }
        let game = GameID()
        let txn = ImportTransaction(source: .file(URL(filePath: "/dev/null")), paths: p)
        let collector = Task { var seen: [ImportState] = []; for await s in await txn.states {
            seen.append(s)
        }; return seen }
        await txn.run { t in
            for s in [
                ImportState.staging(.init()),
                .inspecting,
                .extracting(.init(completedBytes: 1, totalBytes: 2)),
                .normalizing,
                .detecting,
                .resolvingRuntime,
                .analyzingMedia,
                .preparing(.init()),
                .registering,
            ] {
                await t.transition(to: s)
            }
            #expect(await FileManager.default.fileExists(atPath: t.stagingURL.path(percentEncoded: false)))
            return game
        }
        await txn.wait()
        let seen = await collector.value
        #expect(seen.first == .queued)
        #expect(seen.last == .ready(game))
        #expect(seen.count == 11)
        #expect(await txn.visited == seen)
        #expect(!FileManager.default.fileExists(atPath: await txn.stagingURL.path(percentEncoded: false)))
    }

    @Test("Cancellation during extraction rolls back the staging directory")
    func cancellation() async throws {
        let (p, root) = try paths()
        defer { root.remove() }
        let txn = ImportTransaction(source: .file(URL(filePath: "/dev/null")), paths: p)
        await txn.run { t in
            await t.transition(to: .extracting(.init()))
            try await Data([1]).write(to: t.stagingURL.appending(path: "partial.bin"))
            while true {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        await txn.cancel()
        await txn.wait()
        #expect(await txn.state == .cancelled)
        #expect(await !FileManager.default.fileExists(atPath: txn.stagingURL.path(percentEncoded: false)))
    }

    @Test("Failures roll back and carry the reason; storage errors map to storageInsufficient")
    func failures() async throws {
        let (p, root) = try paths()
        defer { root.remove() }
        let a = ImportTransaction(source: .file(URL(filePath: "/x.zip")), paths: p)
        await a.run { _ in throw ImportFailure.noGameRoot }
        await a.wait()
        #expect(await a.state == .failed(.noGameRoot))
        let b = ImportTransaction(source: .file(URL(filePath: "/x.zip")), paths: p)
        await b.run { _ in throw StorageError.insufficientSpace(required: 10, available: 1, reason: "test") }
        await b.wait()
        #expect(await b.state == .failed(.storageInsufficient(required: 10, available: 1)))
        #expect(await !FileManager.default.fileExists(atPath: b.stagingURL.path(percentEncoded: false)))
    }

    @Test("The coordinator runs transactions one at a time")
    func serialCoordinator() async throws {
        let (p, root) = try paths()
        defer { root.remove() }
        let coordinator = ImportCoordinator(paths: p)
        let order = Order()
        var txns: [ImportTransaction] = []
        for i in 0 ..< 3 {
            await txns.append(coordinator.enqueue(source: .folder(URL(filePath: "/f\(i)"))) { _ in
                await order.begin(i)
                try await Task.sleep(for: .milliseconds(20))
                await order.end(i)
                return GameID()
            })
        }
        for t in txns {
            for await s in await t.states where s.isTerminal {
                break
            }
        }
        #expect(await order.events == ["b0", "e0", "b1", "e1", "b2", "e2"])
    }

    @Test("Stale staging directories are swept, fresh ones kept")
    func sweep() throws {
        let (p, root) = try paths()
        defer { root.remove() }
        let old = p.importStaging(txn: UUID())
        let fresh = p.importStaging(txn: UUID())
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -48 * 3600)],
            ofItemAtPath: old.path(percentEncoded: false)
        )
        #expect(ImportCoordinator.sweepStaleStaging(paths: p) == 1)
        #expect(!FileManager.default.fileExists(atPath: old.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: fresh.path(percentEncoded: false)))
    }

    private actor Order {
        var events: [String] = []
        func begin(_ i: Int) { events.append("b\(i)") }
        func end(_ i: Int) { events.append("e\(i)") }
    }
}

@Suite("Container sniffing")
struct ContainerSnifferTests {
    @Test("Every archive fixture is identified by bytes", arguments: [
        ("mv-basic.zip", ContainerKind.zip), ("mv-basic-nested.zip", .zip), ("corrupt.zip", .zip), ("bomb-ratio.zip", .zip),
        ("renpy-apk-min.apk", .zip), ("mv.jgp", .zip), ("symlink.tar", .tar), ("nwjs-appended.exe", .pe), ("godot-embedded.exe", .pe),
        ("mv-basic", .folder), ("unknown-min/file0.bin", .unknown), ("rgss-xp/Game.rgssad", .unknown),
    ])
    func fixtures(name: String, kind: ContainerKind) throws {
        #expect(try ContainerSniffer.identify(Fixtures.url(name)) == kind)
    }

    @Test("A renamed extension changes nothing")
    func renamed() throws {
        let root = try TemporaryGameRoot(name: "sniff")
        let copy = root.url.appending(path: "game.dat")
        try FileManager.default.copyItem(at: Fixtures.url("mv-basic.zip"), to: copy)
        #expect(try ContainerSniffer.identify(copy) == .zip)
        #expect(ContainerSniffer.firstBytesHex(copy).hasPrefix("504b0304"))
    }

    @Test("Magic table covers the formats without fixtures")
    func magics() {
        #expect(ContainerSniffer.identify(header: Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0, 4])) == .sevenZip)
        #expect(ContainerSniffer.identify(header: Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00, 0xCF])) == .rar4)
        #expect(ContainerSniffer.identify(header: Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00])) == .rar5)
        #expect(ContainerSniffer.identify(header: Data([0x1F, 0x8B, 0x08])) == .gzip)
        #expect(ContainerSniffer.identify(header: Data([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])) == .xz)
        #expect(ContainerSniffer.identify(header: Data([0x28, 0xB5, 0x2F, 0xFD])) == .zstd)
        #expect(ContainerSniffer.identify(header: Data("MSCF".utf8) + Data(count: 32)) == .cab)
        var asar = Data([4, 0, 0, 0, 40, 0, 0, 0, 36, 0, 0, 0, 30, 0, 0, 0])
        asar += Data("{\"files\":{\"a\":{\"size\":1}}}".utf8)
        #expect(ContainerSniffer.identify(header: asar) == .asar)
        #expect(ContainerSniffer.identify(header: Data("MZ".utf8) + Data(count: 100)) == .unknown) // DOS stub without PE
        #expect(ContainerSniffer.identify(header: Data()) == .unknown)
    }
}

@Suite("Safety policy")
struct SafetyPolicyTests {
    let validator = EntryValidator()

    @Test("Paths that escape or are malformed are rejected; sane ones extract normalised")
    func paths() {
        var t = RunningTotals()
        #expect(validator.validate(.init(path: "www\\js\\rpg_core.js"), running: &t) == .extract("www/js/rpg_core.js"))
        for bad in ["../../evil.txt", "/etc/x", "C:\\Windows\\x", "a\u{0}b", "game/../../x"] {
            guard case let .reject(v) = validator.validate(.init(path: bad), running: &t) else { Issue.record("\(bad) accepted"); continue }
            #expect(v.rule == .invalidPath)
        }
        #expect(validator.validate(.init(path: "Data/NUL.txt"), running: &t) == .extract("Data/_NUL.txt"))
    }

    @Test("Symlinks, hardlinks and devices are skipped and counted, never extracted")
    func links() {
        var t = RunningTotals()
        for kind in [ArchiveEntryHeader.Kind.symlink, .hardlink, .device, .other] {
            guard case .skip = validator.validate(.init(path: "link", kind: kind), running: &t)
            else { Issue.record("\(kind) not skipped"); continue }
        }
        #expect(t.skipped == 4 && t.entries == 4)
    }

    @Test("Entry count, declared size, per-entry and overall ratios are bounded")
    func bounds() {
        var limits = SafetyLimits()
        limits.maxEntries = 3
        limits.maxUncompressedBytes = 1000
        limits.maxEntryCompressionRatio = 10
        limits.maxOverallCompressionRatio = 5
        let v = EntryValidator(limits: limits)
        var t = RunningTotals()
        #expect(v.validate(.init(path: "a", declaredSize: 500, compressedSize: 100), running: &t) == .extract("a"))
        func rule(_ d: EntryDecision) -> SafetyViolation.Rule? {
            if case let .reject(v) = d {
                v.rule
            } else {
                nil
            }
        }
        #expect(rule(v.validate(.init(path: "b", declaredSize: 400, compressedSize: 1), running: &t)) == .entryRatio)
        #expect(rule(v.validate(.init(path: "c", declaredSize: 200), running: &t)) == .declaredSize)
        #expect(rule(v.validate(.init(path: "d"), running: &t)) == .entryCount)
        var w = RunningTotals()
        w.writtenBytes = 600
        #expect(v.checkWritten(w, sourceBytes: 100)?.rule == .overallRatio)
        #expect(v.checkWritten(w, sourceBytes: 200) == nil)
        w.writtenBytes = 2000
        #expect(v.checkWritten(w, sourceBytes: nil)?.rule == .declaredSize)
        #expect(v.checkNesting(depth: 3)?.rule == .nestingDepth)
        #expect(v.checkNesting(depth: 2) == nil)
    }

    @Test("Post-extraction audit catches symlinks and size mismatches, passes a clean tree")
    func audit() throws {
        let root = try TemporaryGameRoot(name: "audit")
        try root.file("www/index.html", Data(count: 10))
        try root.file("www/js/a.js", Data(count: 5))
        var t = RunningTotals()
        t.declaredBytes = 15
        let audited = try PostExtractionAudit.run(root: root.url, totals: t, sourceBytes: 8)
        #expect(audited.writtenBytes == 15)
        t.declaredBytes = 16
        #expect(throws: SafetyViolation.self) { try PostExtractionAudit.run(root: root.url, totals: t, sourceBytes: 8) }
        try FileManager.default.createSymbolicLink(at: root.url.appending(path: "www/link"), withDestinationURL: URL(filePath: "/etc"))
        t.declaredBytes = 15
        do { _ = try PostExtractionAudit.run(root: root.url, totals: t, sourceBytes: 8); Issue.record("symlink accepted")
        } catch let v as SafetyViolation {
            #expect(v.rule == .symlinkPresent)
        }
    }
}
