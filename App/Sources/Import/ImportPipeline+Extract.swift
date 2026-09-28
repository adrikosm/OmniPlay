import Diagnostics
import Foundation
import GameCore
import GameDetection
import GameImport
import GameStore
import OverlayVFS
import RuntimeCore
import Synchronization

extension ImportPipeline {
    // MARK: Archives

    func extractArchive(
        _ url: URL,
        to stagedRoot: URL,
        txn: ImportTransaction,
        offset: Int64 = 0,
        passphrase: String? = nil
    ) async throws -> RunningTotals {
        if offset == 0 {
            let kind = try ContainerSniffer.identify(url)
            if kind == .rar4 || kind == .rar5 {
                return try await extractRar(url, to: stagedRoot, txn: txn, passphrase: passphrase)
            }
        }
        let extractor = LibArchiveExtractor(limits: limits)
        let hdrcharset = offset == 0 ? try NameDecoder.charset(for: url, extractor: extractor) : nil
        let pre = try extractor.preflight(url, hdrcharset: hdrcharset, offset: offset)
        if pre.encrypted, passphrase == nil {
            throw ImportFailure.passwordRequired
        }
        let hint = pre.sizesKnown ? pre.declaredBytes : (fileSize(url) ?? 0) * 4
        try StorageBudget.require(.forArchive(uncompressedSizeHint: hint), at: paths.root)
        let total: Int64? = pre.sizesKnown ? pre.declaredBytes : nil
        await txn.transition(to: .extracting(.init(completedBytes: 0, totalBytes: total)))
        let reporter = ProgressReporter(txn: txn, total: total)
        do {
            return try extractor
                .extract(url, to: stagedRoot, passphrase: passphrase, hdrcharset: hdrcharset, offset: offset) { done, item in
                    reporter.report(
                        done,
                        item
                    )
                }
        } catch let v as SafetyViolation {
            throw ImportFailure.safetyViolation(v)
        } catch let e as ExtractionError {
            switch e {
            case let .open(m): throw ImportFailure.unreadableSource(m)
            // libarchive reports a wrong password per entry ("Incorrect passphrase"); the player gets to try again.
            case let .entry(_, m) where pre.encrypted && m.localizedCaseInsensitiveContains("passphrase"):
                throw ImportFailure.passwordIncorrect
            case let .entry(path, m), let .unsupportedCompression(path, m): throw ImportFailure.extractionFailed(entry: path, underlying: m)
            case let .write(path, errno): throw ImportFailure.extractionFailed(entry: path, underlying: String(cString: strerror(errno)))
            }
        }
    }

    // MARK: Folders

    func extractCab(_ url: URL, to destination: URL, txn: ImportTransaction) async throws -> RunningTotals {
        let extractor = CabExtractor(limits: limits)
        do {
            let pre = try extractor.preflight(url)
            try StorageBudget.require(.forArchive(uncompressedSizeHint: pre.declaredBytes), at: paths.root)
            await txn.transition(to: .extracting(.init(completedBytes: 0, totalBytes: pre.declaredBytes)))
            let reporter = ProgressReporter(txn: txn, total: pre.declaredBytes)
            return try extractor.extract(url, to: destination) { done, item in reporter.report(done, item) }
        } catch let error as SafetyViolation {
            throw ImportFailure.safetyViolation(error)
        } catch let error as ExtractionError {
            throw ImportFailure.extractionFailed(entry: url.lastPathComponent, underlying: String(describing: error))
        }
    }

    func extractRar(_ url: URL, to destination: URL, txn: ImportTransaction, passphrase: String?) async throws -> RunningTotals {
        let extractor = RarExtractor(limits: limits)
        do {
            let pre = try extractor.preflight(url, passphrase: passphrase)
            if pre.encrypted, passphrase == nil {
                throw ImportFailure.passwordRequired
            }
            try StorageBudget.require(.forArchive(uncompressedSizeHint: pre.declaredBytes), at: paths.root)
            await txn.transition(to: .extracting(.init(completedBytes: 0, totalBytes: pre.declaredBytes)))
            let reporter = ProgressReporter(txn: txn, total: pre.declaredBytes)
            return try extractor.extract(url, to: destination, passphrase: passphrase) { done, item in reporter.report(done, item) }
        } catch let error as SafetyViolation {
            throw ImportFailure.safetyViolation(error)
        } catch let error as ExtractionError {
            throw ImportFailure.extractionFailed(entry: url.lastPathComponent, underlying: String(describing: error))
        }
    }

    func stage(from source: URL, to stagedRoot: URL, txn: ImportTransaction) async throws -> RunningTotals {
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
    func walkSlice(
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

    func detect(
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
