import Diagnostics
import Foundation
import GameCore
import GameDetection
import GameImport
import GameStore
import OverlayVFS
import RuntimeCore
import Synchronization

/// One import from a folder or archive to a registered, sealed, indexed, detected game. Every step that
/// touches bytes is bounded; every failure rolls back to nothing.
struct ImportPipeline: Sendable {
    let paths: AppPaths
    let store: GameStore
    let session: SessionID
    let registry: RuntimeRegistry
    let limits = SafetyLimits.default

    /// What to do when the same source was imported before.
    enum DuplicatePolicy: Sendable { case ask, keepBoth, replace(GameID) }

    /// Answers the user gave to earlier failures of the same source; a re-run carries them all.
    struct Options: Sendable {
        var duplicates: DuplicatePolicy = .ask
        var passphrase: String?
        var chosenRoot: String?
    }

    struct Materialized { let root: URL, totals: RunningTotals, sourceBytes: Int64? }

    func run(_ txn: ImportTransaction, options: Options = Options()) async throws -> GameID {
        let duplicates = options.duplicates
        let source = txn.source
        let staging = txn.stagingURL
        let accessed = source.url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                source.url.stopAccessingSecurityScopedResource()
            }
        }

        let kind = try ContainerSniffer.identify(source.url)
        await txn.transition(to: .inspecting)
        let fingerprint = try SourceFingerprint.compute(source.url)
        if case .ask = duplicates, let previous = try store.imports.find(sha256: fingerprint).compactMap(\.gameId).first,
           let existing = try store.games.fetch(id: previous) {
            throw ImportFailure.duplicate(existing: existing.id, title: existing.title)
        }
        let staged = try await materialize(kind: kind, source: source, staging: staging, txn: txn, passphrase: options.passphrase)

        await txn.transition(to: .normalizing)
        let audited: RunningTotals
        do {
            audited = try PostExtractionAudit.run(root: staged.root, totals: staged.totals, sourceBytes: staged.sourceBytes, limits: limits)
        } catch let v as SafetyViolation {
            throw ImportFailure.safetyViolation(v)
        }
        let located = try GameRootLocator.locate(stagingRoot: staged.root, chosen: options.chosenRoot)
        let gameRoot = located.relativePath.isEmpty ? staged.root : staged.root.appending(
            path: located.relativePath,
            directoryHint: .isDirectory
        )

        await txn.transition(to: .detecting)
        let title = Self.title(from: source.url)
        let report = try detect(root: gameRoot, located: located, source: source, title: title, fingerprint: fingerprint)
        await txn.transition(to: .resolvingRuntime)
        let resolution = await RuntimeResolver(registry: registry).resolve(report)

        await txn.transition(to: .registering)
        let plan = CommitPlan(
            stagedRoot: staged.root,
            located: located,
            title: report.descriptor.title.isEmpty ? title : report.descriptor.title,
            report: report,
            resolution: resolution,
            bytes: audited.writtenBytes,
            source: source,
            fingerprint: fingerprint
        )
        if case let .replace(existing) = duplicates {
            return try await replace(existing, with: plan)
        }
        return try await commit(plan)
    }

    // MARK: Materialize

    /// Copies a folder or extracts an archive (unwrapping one nested level) into staging.
    func materialize(
        kind: ContainerKind,
        source: ImportSource,
        staging: URL,
        txn: ImportTransaction,
        passphrase: String?
    ) async throws -> Materialized {
        var stagedRoot = staging.appending(path: "Original", directoryHint: .isDirectory)
        var totals: RunningTotals
        var sourceBytes: Int64?
        switch kind {
        case .folder:
            totals = try await stage(from: source.url, to: stagedRoot, txn: txn)
        case .cab:
            totals = try await extractCab(source.url, to: stagedRoot, txn: txn)
            sourceBytes = fileSize(source.url)
        case .zip, .sevenZip, .tar, .gzip, .xz, .zstd, .rar4, .rar5:
            totals = try await extractArchive(source.url, to: stagedRoot, txn: txn, passphrase: passphrase)
            sourceBytes = (kind == .rar4 || kind == .rar5) ? try RarExtractor.sourceBytes(source.url) : fileSize(source.url)
            var depth = 1
            while let inner = GameRootLocator.nestedArchive(in: stagedRoot) {
                depth += 1
                if let v = EntryValidator(limits: limits).checkNesting(depth: depth) {
                    throw ImportFailure.safetyViolation(v)
                }
                let next = staging.appending(path: "Original-\(depth)", directoryHint: .isDirectory)
                totals = try await extractArchive(inner, to: next, txn: txn, passphrase: passphrase)
                let innerKind = try ContainerSniffer.identify(inner)
                sourceBytes = (innerKind == .rar4 || innerKind == .rar5) ? try RarExtractor.sourceBytes(inner) : fileSize(inner)
                try FileManager.default.removeItem(at: stagedRoot)
                stagedRoot = next
            }
            if let installer = Self.loneInstaller(in: stagedRoot) {
                let next = staging.appending(path: "Original-installer", directoryHint: .isDirectory)
                (totals, sourceBytes) = try await extractInstaller(installer, to: next, txn: txn, passphrase: passphrase)
                try FileManager.default.removeItem(at: stagedRoot)
                stagedRoot = next
            }
        case .pe:
            (totals, sourceBytes) = try await extractInstaller(source.url, to: stagedRoot, txn: txn, passphrase: passphrase)
        case .asar:
            totals = try await extractAsar(source.url, to: stagedRoot, txn: txn)
            sourceBytes = fileSize(source.url)
        case .unknown:
            throw ImportFailure.unsupportedContainer(firstBytesHex: ContainerSniffer.firstBytesHex(source.url))
        }
        if let asar = Self.electronArchive(in: stagedRoot) {
            // Electron layout: resources/app.asar (+ app.asar.unpacked) becomes resources/app/ so the locator sees files.
            let unpackedSibling = asar.deletingLastPathComponent().appending(
                path: asar.lastPathComponent + ".unpacked",
                directoryHint: .isDirectory
            )
            var removedBytes = fileSize(asar) ?? 0
            try? LazyDirectoryWalker.walk(root: unpackedSibling) { removedBytes += $0.fileSize; return .continue }
            let more = try await extractAsar(
                asar,
                to: asar.deletingLastPathComponent().appending(path: "app", directoryHint: .isDirectory),
                txn: txn
            )
            try? FileManager.default.removeItem(at: asar)
            try? FileManager.default.removeItem(at: unpackedSibling)
            // The audit compares declared bytes with what is on disk; the archive left, its contents arrived.
            totals.writtenBytes += more.writtenBytes - removedBytes
            if totals.declaredBytes > 0 {
                totals.declaredBytes += more.writtenBytes - removedBytes
            }
            totals.entries += more.entries
        }
        return Materialized(root: stagedRoot, totals: totals, sourceBytes: sourceBytes)
    }

    /// A Windows installer or self-extractor: the game data inside it, never the program itself (Godot packs excepted).
    func extractInstaller(
        _ url: URL,
        to stagedRoot: URL,
        txn: ImportTransaction,
        passphrase: String?
    ) async throws -> (RunningTotals, Int64?) {
        var totals: RunningTotals
        var sourceBytes: Int64?
        guard let payload = try PEOverlayScanner.scan(url)
        else { throw ImportFailure.unsupportedContainer(firstBytesHex: "malformed executable") }
        switch payload.kind {
        case .cab:
            // libmspack finds the cabinet inside the installer itself.
            totals = try await extractCab(url, to: stagedRoot, txn: txn)
            sourceBytes = fileSize(url)
        case let .appendedZip(offset), let .appendedSevenZip(offset):
            totals = try await extractArchive(url, to: stagedRoot, txn: txn, offset: offset, passphrase: passphrase)
            sourceBytes = fileSize(url).map { $0 - offset }
        case .godotPCK:
            // Godot opens its own self-contained executables (`--main-pack Game.exe` finds the pack from the tail),
            // and a pack's offsets can be absolute within the .exe, so the file is kept whole rather than cut out.
            let size = fileSize(url) ?? 0
            try StorageBudget.require(.forCopy(bytes: size), at: paths.root)
            await txn.transition(to: .staging(.init(completedBytes: 0, totalBytes: size)))
            try FileManager.default.createDirectory(at: stagedRoot, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: stagedRoot.appending(path: url.lastPathComponent))
            totals = RunningTotals()
            totals.entries = 1
            totals.declaredBytes = size
            totals.writtenBytes = size
            sourceBytes = size
        case .enigmaVB: throw ImportFailure.unsupportedContainer(firstBytesHex: "Enigma Virtual Box executable is not supported yet")
        case .appendedRar:
            totals = try await extractRar(url, to: stagedRoot, txn: txn, passphrase: passphrase)
            sourceBytes = fileSize(url)
        case .none: throw ImportFailure.unsupportedContainer(firstBytesHex: "a Windows program with no game data inside")
        }
        return (totals, sourceBytes)
    }

    /// The staged tree is one Windows installer and nothing else (macOS resource forks aside), as when a site zips up
    /// `Game.exe`. Only installers with an embedded archive count; a bare game program is left alone.
    static func loneInstaller(in root: URL) -> URL? {
        var files: [URL] = []
        try? LazyDirectoryWalker.walk(root: root) { entry in
            if entry.isDirectory {
                return entry.url.lastPathComponent == "__MACOSX" ? .skipDescendants : .continue
            }
            if !entry.url.lastPathComponent.hasPrefix(".") {
                files.append(entry.url)
            }
            return files.count > 1 ? .stop : .continue
        }
        guard files.count == 1, (try? ContainerSniffer.identify(files[0])) == .pe,
              let payload = try? PEOverlayScanner.scan(files[0]) else { return nil }
        switch payload.kind {
        case .cab, .appendedZip, .appendedSevenZip, .appendedRar: return files[0]
        default: return nil
        }
    }

    /// `resources/app.asar` up to two levels below the staged root.
    static func electronArchive(in root: URL) -> URL? {
        var found: URL?
        try? LazyDirectoryWalker.walk(root: root) { entry in
            if entry.relativePath.split(separator: "/").count > 3 {
                return .skipDescendants
            }
            if !entry.isDirectory, entry.url.lastPathComponent == "app.asar",
               entry.url.deletingLastPathComponent().lastPathComponent == "resources" {
                found = entry.url
                return .stop
            }
            return .continue
        }
        return found
    }

    func extractAsar(_ url: URL, to stagedRoot: URL, txn: ImportTransaction) async throws -> RunningTotals {
        await txn.transition(to: .extracting(.init(completedBytes: 0, totalBytes: fileSize(url))))
        do {
            return try AsarExtractor(limits: limits).extract(url, to: stagedRoot)
        } catch let v as SafetyViolation {
            throw ImportFailure.safetyViolation(v)
        }
    }
}

/// Throttles extraction progress into transaction states (at most five updates a second).
final class ProgressReporter: Sendable {
    private let txn: ImportTransaction
    private let total: Int64?
    private let last = Mutex<Date>(.distantPast)

    init(txn: ImportTransaction, total: Int64?) {
        self.txn = txn
        self.total = total
    }

    func report(_ done: Int64, _ item: String) {
        let due = last.withLock { l in
            guard Date.now.timeIntervalSince(l) > 0.2 else { return false }
            l = .now
            return true
        }
        guard due else { return }
        let txn = txn, total = total
        Task { await txn.progress(.init(completedBytes: done, totalBytes: total, currentItem: item)) }
    }
}
