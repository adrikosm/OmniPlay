import Foundation

public struct StorageEstimate: Sendable, Hashable {
    /// Bytes that stay on disk when the operation succeeds.
    public var required: Int64
    /// Bytes needed only while the operation runs.
    public var temporary: Int64
    public var reason: String

    public init(required: Int64, temporary: Int64 = 0, reason: String) {
        self.required = required
        self.temporary = temporary
        self.reason = reason
    }

    public static func forArchive(uncompressedSizeHint: Int64) -> StorageEstimate {
        .init(required: uncompressedSizeHint, temporary: uncompressedSizeHint, reason: "extract archive (staging + commit)")
    }

    public static func forCopy(bytes: Int64) -> StorageEstimate { .init(required: bytes, reason: "copy files") }
    public static func forTranscode(inputBytes: Int64, ratio: Double = 1.0) -> StorageEstimate {
        .init(required: Int64(Double(inputBytes) * ratio), temporary: inputBytes, reason: "transcode media")
    }

    public static func forBackup(bytes: Int64) -> StorageEstimate { .init(required: bytes, reason: "back up saves") }
}

public enum StorageVerdict: Sendable, Hashable {
    case ok(headroom: Int64)
    case insufficient(required: Int64, available: Int64, shortfall: Int64)
    /// Capacity could not be read; callers proceed and log a warning under `filesystem`.
    case unknown

    public var isBlocking: Bool {
        if case .insufficient = self {
            true
        } else {
            false
        }
    }
}

/// Fails an operation before it fills the disk: keeps a 1 GiB reserve and counts temporary space at 1.5×.
public enum StorageBudget {
    public static let reserve: Int64 = 1 << 30
    public static let temporaryMultiplier = 1.5

    public static func needed(for estimate: StorageEstimate) -> Int64 {
        estimate.required + Int64(Double(estimate.temporary) * temporaryMultiplier) + reserve
    }

    public static func check(_ estimate: StorageEstimate, at url: URL) -> StorageVerdict {
        guard let available = try? VolumeSpace.available(at: url) else { return .unknown }
        return check(estimate, available: available)
    }

    public static func check(_ estimate: StorageEstimate, available: Int64) -> StorageVerdict {
        let need = needed(for: estimate)
        return available >= need
            ? .ok(headroom: available - need)
            : .insufficient(required: need, available: available, shortfall: need - available)
    }

    /// Throws `StorageError.insufficientSpace` when the verdict blocks.
    public static func require(_ estimate: StorageEstimate, at url: URL) throws {
        if case let .insufficient(required, available, _) = check(estimate, at: url) {
            throw StorageError.insufficientSpace(required: required, available: available, reason: estimate.reason)
        }
    }
}
