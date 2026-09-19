import Diagnostics
import Foundation
import GameCore
import GameDetection
import GameImport
import GameStore
import OverlayVFS

/// One import from a folder to a registered, sealed, indexed game. Archives are refused until the
/// libarchive extractor lands; everything that runs here is the commit path those extractors will share.
struct ImportPipeline: Sendable {
    let paths: AppPaths
    let store: GameStore
    let session: SessionID
    let limits = SafetyLimits.default

    func run(_ txn: ImportTransaction) async throws -> GameID {
        let source = txn.source
        let staging = txn.stagingURL
        let accessed = source.url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                source.url.stopAccessingSecurityScopedResource()
            }
        }

        let kind = try ContainerSniffer.identify(source.url)
        guard kind == .folder else {
            throw ImportFailure.unsupportedContainer(firstBytesHex: "\(kind.rawValue): archive import arrives with the next milestone")
        }
        let stagedRoot = staging.appending(path: "Original", directoryHint: .isDirectory)
        let totals = try await stage(from: source.url, to: stagedRoot, txn: txn)

        await txn.transition(to: .inspecting)
        let audited: RunningTotals
        do { audited = try PostExtractionAudit.run(root: stagedRoot, totals: totals, sourceBytes: nil, limits: limits)
        } catch let v as SafetyViolation {
            throw ImportFailure.safetyViolation(v)
        }

        await txn.transition(to: .detecting)
        let detection = try detect(root: stagedRoot)

        await txn.transition(to: .registering)
        return try await commit(
            stagedRoot: stagedRoot,
            title: Self.title(from: source.url),
            detection: detection,
            bytes: audited.writtenBytes,
            source: source,
            txn: txn
        )
    }

    // MARK: Staging

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
        // The walk is synchronous; copies are collected per 64 entries so the async copier never runs inside the enumerator.
        var stop: SafetyViolation?
        func drain() async throws {
            for (url, rel) in pending {
                try Task.checkCancellation()
                try await ChunkedCopier.copy(from: url, to: stagedRoot.appending(path: rel)) { _ in }
                copied += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                if Date.now.timeIntervalSince(lastReport) > 0.2 {
                    lastReport = .now
                    await txn.transition(to: .staging(.init(completedBytes: copied, totalBytes: totalBytes, currentItem: rel)))
                }
            }
            pending.removeAll(keepingCapacity: true)
        }
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
            try await drain()
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

    // MARK: Detection (structure-only until Epic 3)

    private func detect(root: URL) throws -> DetectionResult {
        let tree = try DirectoryGameTree(root: root)
        if let hit = try RGSSArchiveSignature().evaluate(tree) {
            return hit
        }
        return DetectionResult(
            engine: .unknown,
            confidence: 0,
            evidence: [.init(check: "structure", outcome: "no signature matched", weight: 0)]
        )
    }

    // MARK: Commit

    private func commit(
        stagedRoot: URL,
        title: String,
        detection: DetectionResult,
        bytes: Int64,
        source: ImportSource,
        txn: ImportTransaction
    ) async throws -> GameID {
        let id = GameID()
        let gameRoot = paths.game(id)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: gameRoot, withIntermediateDirectories: true)
            for tier in [ContentTier.overrides, .generated, .saves, .artwork] {
                try fm.createDirectory(at: paths.tier(tier, for: id), withIntermediateDirectories: true)
            }
            let original = paths.tier(.original, for: id)
            try fm.moveItem(at: stagedRoot, to: original)
            try OriginalGuard.seal(originalRoot: original, manifest: gameRoot.appending(path: "original.manifest"))
            try PathIndex.open(at: gameRoot.appending(path: "index.sqlite")).build(layer: "original", root: original)

            let descriptor = GameDescriptor(
                id: id,
                title: title,
                engine: detection.engine,
                confidence: detection.confidence,
                evidence: detection.evidence,
                identityHash: id.description,
                grade: detection.engine.tier == .refused ? .refused : .loadable
            )
            try JSONEncoder().encode(descriptor).write(to: gameRoot.appending(path: "game.json"), options: .atomic)

            var record = GameRecord(id: id, title: title, engine: detection.engine)
            record.detectionConfidence = detection.confidence
            record.compatibilityState = descriptor.grade
            record.installBytes = bytes
            record.version = detection.engineVersion
            try store.games.insert(record)
            _ = try store.detection.saveResult(.init(
                gameId: id,
                outcome: detection.engine.rawValue,
                confidence: detection.confidence,
                evidence: detection.evidence,
                detectorVersions: ["rgss-archive-magic": "1"]
            ))
            _ = try store.imports.record(.init(
                gameId: id,
                sourceName: source.url.lastPathComponent,
                container: "folder",
                sourceSha256: "",
                bytes: bytes,
                outcome: "ok"
            ))
            OPLog.log(.importer, .info, "registered \(id) \(title) as \(detection.engine.rawValue)", session: session)
            return id
        } catch {
            try? OriginalGuard.unseal(originalRoot: paths.tier(.original, for: id))
            try? fm.removeItem(at: gameRoot)
            throw error
        }
    }

    static func title(from url: URL) -> String {
        let raw = url.deletingPathExtension().lastPathComponent
        let cleaned = raw.replacingOccurrences(of: "[_\\.]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Untitled game" : cleaned
    }
}

/// Read-only probe over a staged directory for the detection signatures.
/// ponytail: the path list is materialised (fine for the RGSS signature); Epic 3's structure inspector streams instead.
struct DirectoryGameTree: GameTreeProbe {
    let root: URL
    let paths: [String]

    init(root: URL) throws {
        self.root = root
        var list: [String] = []
        try LazyDirectoryWalker.walk(root: root) {
            if !$0.isDirectory {
                list.append($0.relativePath)
            }; return .continue
        }
        paths = list
    }

    func readPrefix(of relativePath: String, maxBytes: Int) throws -> Data? {
        let url = root.appending(path: relativePath)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return try BoundedReader.readHeader(url: url, bytes: maxBytes)
    }
}
