import Diagnostics
import Foundation
import GameCore

public enum PersistError: Error {
    case validationFailed(String)
    case swapFailed(String)
    case verifyFailed(String)
}

/// Every persistent modification runs through this: Inspect → Backup → Mutate (on clones) → Validate → Persist →
/// Reload → Verify. Any failure restores the snapshot, so the previous state is always recoverable.
public struct SafePersistTransaction: Sendable {
    /// Clones of the target files the mutation edits; `url(for:)` maps a live target to its staged copy.
    public struct Staging: Sendable {
        let mapping: [URL: URL]
        public func url(for target: URL) -> URL { mapping[target.standardizedFileURL] ?? target }
    }

    public let location: SaveLocation
    public let identityHash: String

    public init(location: SaveLocation, identityHash: String) {
        self.location = location
        self.identityHash = identityHash
    }

    public func run<T: Sendable>(
        targets: [URL],
        reason: SaveProvenance.Origin = .beforeEdit,
        mutate: @Sendable (Staging) async throws -> T,
        validate: @Sendable (Staging) throws -> Void = { _ in },
        verifyAfterReload: (@Sendable () async throws -> Void)? = nil
    ) async throws -> T {
        let fm = FileManager.default
        try location.ensure()
        let backup = try await SaveVault.snapshot(location: location, identityHash: identityHash, reason: reason)
        let backupDir = SaveVault.snapshots(location: location).first { $0.manifest.id == backup.id }?.directory
        let stagingDir = location.root.appending(path: ".txn-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingDir) }
        var mapping: [URL: URL] = [:]
        for (i, target) in targets.enumerated() {
            let staged = stagingDir.appending(path: "\(i)-\(target.lastPathComponent)")
            if fm.fileExists(atPath: target.path(percentEncoded: false)) {
                try await APFSClone.clone(from: target, to: staged)
            }
            mapping[target.standardizedFileURL] = staged
        }
        let staging = Staging(mapping: mapping)
        let result = try await mutate(staging)
        do { try validate(staging) } catch { throw PersistError.validationFailed(String(describing: error)) }
        try swap(staging: staging)
        if let verifyAfterReload {
            do {
                try await verifyAfterReload()
            } catch {
                if let backupDir {
                    try? await SaveVault.restore(
                        snapshot: backupDir,
                        into: location,
                        identityHash: identityHash,
                        mode: .replace
                    )
                }
                throw PersistError.verifyFailed(String(describing: error))
            }
        }
        OPLog.log(.save, .info, "persisted \(targets.count) files (\(reason.rawValue))")
        return result
    }

    /// Rename per file with a rollback list; staged files missing after `mutate` delete their targets.
    private func swap(staging: Staging) throws {
        let fm = FileManager.default
        var rolledBack: [(aside: URL, live: URL)] = []
        do {
            for (live, staged) in staging.mapping {
                let aside = live.deletingLastPathComponent().appending(path: ".swap-\(UUID().uuidString)")
                if fm.fileExists(atPath: live.path(percentEncoded: false)) {
                    try fm.moveItem(at: live, to: aside)
                }
                rolledBack.append((aside, live))
                if fm.fileExists(atPath: staged.path(percentEncoded: false)) {
                    try fm.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: staged, to: live)
                }
            }
        } catch {
            for (aside, live) in rolledBack.reversed() {
                try? fm.removeItem(at: live)
                if fm.fileExists(atPath: aside.path(percentEncoded: false)) {
                    try? fm.moveItem(at: aside, to: live)
                }
            }
            throw PersistError.swapFailed(String(describing: error))
        }
        for (aside, _) in rolledBack {
            try? fm.removeItem(at: aside)
        }
    }
}
