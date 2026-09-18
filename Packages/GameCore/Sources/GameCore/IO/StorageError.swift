import Foundation

public enum StorageError: Error, Equatable, Sendable {
    case insufficientSpace(required: Int64, available: Int64, reason: String)

    /// Maps an `ENOSPC` from Foundation or POSIX onto `insufficientSpace`; anything else passes through.
    static func map(_ error: Error, required: Int64, at url: URL) -> Error {
        var e: NSError? = error as NSError
        while let n = e {
            if n.domain == NSPOSIXErrorDomain, n.code == Int(ENOSPC) {
                return StorageError.insufficientSpace(
                    required: required,
                    available: (try? VolumeSpace.available(at: url)) ?? 0,
                    reason: "write to \(url.lastPathComponent)"
                )
            }
            e = n.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return error
    }
}

public enum VolumeSpace {
    /// Bytes the system will let an important operation use (the number Files.app shows).
    public static func available(at url: URL) throws -> Int64 {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path(percentEncoded: false)), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let values = try probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
