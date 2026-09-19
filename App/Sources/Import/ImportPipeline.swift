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

    struct Materialized { let root: URL, totals: RunningTotals, sourceBytes: Int64? }

    func run(_ txn: ImportTransaction, duplicates: DuplicatePolicy = .ask) async throws -> GameID {
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
        let staged = try await materialize(kind: kind, source: source, staging: staging, txn: txn)

        await txn.transition(to: .normalizing)
        let audited: RunningTotals
        do {
            audited = try PostExtractionAudit.run(root: staged.root, totals: staged.totals, sourceBytes: staged.sourceBytes, limits: limits)
        } catch let v as SafetyViolation {
            throw ImportFailure.safetyViolation(v)
        }
        let located = try GameRootLocator.locate(stagingRoot: staged.root)
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
    private func materialize(kind: ContainerKind, source: ImportSource, staging: URL, txn: ImportTransaction) async throws -> Materialized {
        var stagedRoot = staging.appending(path: "Original", directoryHint: .isDirectory)
        var totals: RunningTotals
        var sourceBytes: Int64?
        switch kind {
        case .folder:
            totals = try await stage(from: source.url, to: stagedRoot, txn: txn)
        case .zip, .sevenZip, .tar, .gzip, .xz, .zstd:
            totals = try await extractArchive(source.url, to: stagedRoot, txn: txn)
            sourceBytes = fileSize(source.url)
            var depth = 1
            while let inner = GameRootLocator.nestedArchive(in: stagedRoot) {
                depth += 1
                if let v = EntryValidator(limits: limits).checkNesting(depth: depth) {
                    throw ImportFailure.safetyViolation(v)
                }
                let next = staging.appending(path: "Original-\(depth)", directoryHint: .isDirectory)
                totals = try await extractArchive(inner, to: next, txn: txn)
                sourceBytes = fileSize(inner)
                try FileManager.default.removeItem(at: stagedRoot)
                stagedRoot = next
            }
        case .pe:
            guard let payload = try PEOverlayScanner.scan(source.url)
            else { throw ImportFailure.unsupportedContainer(firstBytesHex: "malformed executable") }
            switch payload.kind {
            case let .appendedZip(offset), let .appendedSevenZip(offset):
                totals = try await extractArchive(source.url, to: stagedRoot, txn: txn, offset: offset)
                sourceBytes = fileSize(source.url).map { $0 - offset }
            case .godotPCK: throw ImportFailure
                .unsupportedContainer(firstBytesHex: "Godot executable: embedded PCK support arrives with the Godot epic")
            case .enigmaVB: throw ImportFailure.unsupportedContainer(firstBytesHex: "Enigma Virtual Box executable is not supported yet")
            case .appendedRar,
                 .cab: throw ImportFailure.unsupportedContainer(firstBytesHex: "self-extracting RAR/CAB installers are not supported yet")
            case .none: throw ImportFailure.unsupportedContainer(firstBytesHex: "a Windows program with no game data inside")
            }
        case .rar4, .rar5, .cab, .asar, .unknown:
            throw ImportFailure
                .unsupportedContainer(firstBytesHex: kind == .unknown ? ContainerSniffer.firstBytesHex(source.url) : kind.rawValue)
        }
        return Materialized(root: stagedRoot, totals: totals, sourceBytes: sourceBytes)
    }

    // MARK: Archives

    private func extractArchive(_ url: URL, to stagedRoot: URL, txn: ImportTransaction, offset: Int64 = 0) async throws -> RunningTotals {
        let extractor = LibArchiveExtractor(limits: limits)
        let hdrcharset = offset == 0 ? try NameDecoder.charset(for: url, extractor: extractor) : nil
        let pre = try extractor.preflight(url, hdrcharset: hdrcharset, offset: offset)
        if pre.encrypted {
            throw ImportFailure.passwordRequired
        }
        let hint = pre.sizesKnown ? pre.declaredBytes : (fileSize(url) ?? 0) * 4
        try StorageBudget.require(.forArchive(uncompressedSizeHint: hint), at: paths.root)
        let total: Int64? = pre.sizesKnown ? pre.declaredBytes : nil
        await txn.transition(to: .extracting(.init(completedBytes: 0, totalBytes: total)))
        let reporter = ProgressReporter(txn: txn, total: total)
        do {
            return try extractor.extract(url, to: stagedRoot, hdrcharset: hdrcharset, offset: offset) { done, item in reporter.report(
                done,
                item
            ) }
        } catch let v as SafetyViolation {
            throw ImportFailure.safetyViolation(v)
        } catch let e as ExtractionError {
            switch e {
            case let .open(m): throw ImportFailure.unreadableSource(m)
            case let .entry(path, m), let .unsupportedCompression(path, m): throw ImportFailure.extractionFailed(entry: path, underlying: m)
            case let .write(path, errno): throw ImportFailure.extractionFailed(entry: path, underlying: String(cString: strerror(errno)))
            }
        }
    }

    // MARK: Folders

    private func stage(from source: URL, to stagedRoot: URL, txn: ImportTransaction) async throws -> RunningTotals {
        var totalBytes: Int64 = 0
        try LazyDirectoryWalker.walk(root: source, skipHidden: false) { totalBytes += $0.fileSize; return .continue }
        try StorageBudget.require(.forCopy(bytes: totalBytes), at: paths.root)
        await txn.transition(to: .staging(.init(completedBytes: 0, totalBytes: totalBytes)))
        let validator = EntryValidator(limits: limits)
        var totals = RunningTotals()
        var copied: Int64 = 0
        var lastReport = Date.distantPast
        var pending: [(URL, String)] = []
        var resume: String?
        repeat {
            let more = try walkSlice(
                source: source,
                stagedRoot: stagedRoot,
                validator: validator,
                resume: &resume,
                totals: &totals,
                pending: &pending
            )
            for (url, rel) in pending {
                try Task.checkCancellation()
                try await ChunkedCopier.copy(from: url, to: stagedRoot.appending(path: rel)) { _ in }
                copied += fileSize(url) ?? 0
                if Date.now.timeIntervalSince(lastReport) > 0.2 {
                    lastReport = .now
                    await txn.transition(to: .staging(.init(completedBytes: copied, totalBytes: totalBytes, currentItem: rel)))
                }
            }
            pending.removeAll(keepingCapacity: true)
            if !more {
                break
            }
        } while true
        totals.writtenBytes = copied
        return totals
    }

    /// Walks up to 64 files past `resume`, validating each; returns true when more entries may follow.
    private func walkSlice(
        source: URL,
        stagedRoot: URL,
        validator: EntryValidator,
        resume: inout String?,
        totals: inout RunningTotals,
        pending: inout [(URL, String)]
    ) throws -> Bool {
        var skipping = resume != nil
        var stop: SafetyViolation?
        var last = resume
        try LazyDirectoryWalker.walk(root: source, skipHidden: false) { entry in
            if skipping {
                if entry.relativePath == resume {
                    skipping = false
                }; return .continue
            }
            let isLink = (try? entry.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
            let kind: ArchiveEntryHeader.Kind = isLink ? .symlink : entry.isDirectory ? .directory : .file
            switch validator.validate(.init(path: entry.relativePath, kind: kind, declaredSize: entry.fileSize), running: &totals) {
            case let .reject(v): stop = v; return .stop
            case .skip: return isLink ? .skipDescendants : .continue
            case let .extract(rel):
                if entry.isDirectory {
                    try FileManager.default.createDirectory(at: stagedRoot.appending(path: rel), withIntermediateDirectories: true)
                } else {
                    pending.append((entry.url, rel))
                }
                last = entry.relativePath
                return pending.count >= 64 ? .stop : .continue
            }
        }
        if let stop {
            throw ImportFailure.safetyViolation(stop)
        }
        resume = last
        return pending.count >= 64
    }

    // MARK: Detection

    private func detect(
        root: URL,
        located: LocatedRoot,
        source: ImportSource,
        title: String,
        fingerprint: String
    ) throws -> DetectionReport {
        let payload = try? PEOverlayScanner.scan(source.url)
        let ctx = try ScanContext(root: root, sidecars: located.sidecars, pePayload: payload)
        defer { ctx.close() }
        return DetectionPipeline.standard.run(ctx, title: title, identityHash: fingerprint, rootRelativePath: located.relativePath)
    }

    func fileSize(_ url: URL) -> Int64? { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) }

    static func title(from url: URL) -> String {
        let raw = url.deletingPathExtension().lastPathComponent
        let cleaned = raw.replacingOccurrences(of: "[_\\.]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Untitled game" : cleaned
    }
}

/// Throttles extraction progress into transaction states (at most five updates a second).
private final class ProgressReporter: Sendable {
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
        Task { await txn.transition(to: .extracting(.init(completedBytes: done, totalBytes: total, currentItem: item))) }
    }
}
