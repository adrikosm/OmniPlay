import Foundation

/// Limits every extractor and content installer enforces; `ImportLimits` is the same struct under its older name.
public typealias SafetyLimits = ImportLimits

public struct SafetyViolation: Error, Sendable, Hashable {
    public enum Rule: String, Sendable, Codable {
        case invalidPath, entryCount, declaredSize, entryRatio, overallRatio, symlinkPresent, sizeMismatch, nestingDepth
    }

    public let rule: Rule
    public let entryPath: String?
    public let detail: String

    public init(rule: Rule, entryPath: String? = nil, detail: String) {
        self.rule = rule
        self.entryPath = entryPath
        self.detail = detail
    }
}

public struct ArchiveEntryHeader: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case file, directory, symlink, hardlink, device, other }
    public let path: String
    public let kind: Kind
    public let declaredSize: Int64?
    public let compressedSize: Int64?

    public init(path: String, kind: Kind = .file, declaredSize: Int64? = nil, compressedSize: Int64? = nil) {
        self.path = path
        self.kind = kind
        self.declaredSize = declaredSize
        self.compressedSize = compressedSize
    }
}

/// A few integers carried across an extraction; never a list of entries.
public struct RunningTotals: Sendable, Hashable {
    public var entries = 0
    public var skipped = 0
    public var declaredBytes: Int64 = 0
    public var compressedBytes: Int64 = 0
    public var writtenBytes: Int64 = 0
    public init() {}
}

public enum EntryDecision: Sendable, Hashable {
    /// Extract to this normalised relative path.
    case extract(String)
    /// Symlinks, hardlinks, devices: not extracted, counted.
    case skip(reason: String)
    case reject(SafetyViolation)
}

/// Per-entry checks, applied before any byte is written. Containment is decided on the logical path
/// (never by comparing filesystem prefixes). Duplicate keys are resolved at write time: the first wins.
public struct EntryValidator: Sendable {
    public let limits: SafetyLimits
    private let paths: ImportPathValidator

    public init(limits: SafetyLimits = .default) {
        self.limits = limits
        paths = ImportPathValidator(limits: limits)
    }

    public func validate(_ entry: ArchiveEntryHeader, running: inout RunningTotals) -> EntryDecision {
        running.entries += 1
        if running.entries > limits.maxEntries {
            return .reject(.init(rule: .entryCount, entryPath: entry.path, detail: "more than \(limits.maxEntries) entries"))
        }
        let normalised: String
        do { normalised = try paths.validate(entry.path) } catch {
            return .reject(.init(rule: .invalidPath, entryPath: entry.path, detail: String(describing: error)))
        }
        if hasDriveLetter(normalised) {
            return .reject(.init(rule: .invalidPath, entryPath: entry.path, detail: "Windows drive letter"))
        }
        switch entry.kind {
        case .symlink, .hardlink, .device, .other:
            running.skipped += 1
            return .skip(reason: "\(entry.kind) entries are never extracted")
        case .directory, .file: break
        }
        if let size = entry.declaredSize {
            if size < 0 {
                return .reject(.init(rule: .declaredSize, entryPath: entry.path, detail: "negative size"))
            }
            if UInt64(size) > limits.maxUncompressedBytes || running.declaredBytes > Int64.max - size ||
                UInt64(running.declaredBytes) + UInt64(size) > limits.maxUncompressedBytes {
                return .reject(.init(
                    rule: .declaredSize,
                    entryPath: entry.path,
                    detail: "declared total exceeds \(limits.maxUncompressedBytes) bytes"
                ))
            }
            running.declaredBytes += size
            let ratioApplies = size > limits.minBytesForRatioCheck
            if let c = entry.compressedSize, c > 0, ratioApplies, Double(size) / Double(c) > limits.maxEntryCompressionRatio {
                return .reject(.init(
                    rule: .entryRatio,
                    entryPath: entry.path,
                    detail: "ratio \(size / c):1 exceeds \(Int(limits.maxEntryCompressionRatio)):1"
                ))
            }
            if let c = entry.compressedSize {
                running.compressedBytes += c
            }
        }
        return .extract(normalised)
    }

    private func hasDriveLetter(_ path: String) -> Bool {
        let scalars = Array(path.unicodeScalars.prefix(2))
        return scalars.count == 2 && scalars[1] == ":" && CharacterSet.letters.contains(scalars[0])
    }

    /// Running check for extractors that learn sizes only while writing (headers lie, or are absent).
    public func checkWritten(_ totals: RunningTotals, sourceBytes: Int64?) -> SafetyViolation? {
        if totals.writtenBytes < 0 || UInt64(totals.writtenBytes) > limits.maxUncompressedBytes {
            return .init(rule: .declaredSize, detail: "written \(totals.writtenBytes) bytes exceeds \(limits.maxUncompressedBytes)")
        }
        let ratioApplies = totals.writtenBytes > limits.minBytesForRatioCheck
        if let src = sourceBytes, src > 0, ratioApplies, Double(totals.writtenBytes) / Double(src) > limits.maxOverallCompressionRatio {
            return .init(
                rule: .overallRatio,
                detail: "overall ratio \(totals.writtenBytes / src):1 exceeds \(Int(limits.maxOverallCompressionRatio)):1"
            )
        }
        return nil
    }

    public func checkNesting(depth: Int) -> SafetyViolation? {
        depth > limits.maxNestedArchives ? .init(
            rule: .nestingDepth,
            detail: "nested archive depth \(depth) exceeds \(limits.maxNestedArchives)"
        ) : nil
    }
}

/// After extraction: no symlinks on disk, bytes written match declared sizes when known, overall ratio holds.
public enum PostExtractionAudit {
    public static func run(root: URL, totals: RunningTotals, sourceBytes: Int64?, limits: SafetyLimits = .default) throws -> RunningTotals {
        var audited = totals
        audited.writtenBytes = 0
        var violation: SafetyViolation?
        try walk(root) { url, values in
            if values.isSymbolicLink == true {
                violation = violation ?? .init(rule: .symlinkPresent, entryPath: url.lastPathComponent, detail: "symbolic link on disk")
            }
            audited.writtenBytes += Int64(values.fileSize ?? 0)
        }
        if let violation {
            throw violation
        }
        if totals.declaredBytes > 0, audited.writtenBytes != totals.declaredBytes {
            throw SafetyViolation(rule: .sizeMismatch, detail: "declared \(totals.declaredBytes) bytes, wrote \(audited.writtenBytes)")
        }
        if let v = EntryValidator(limits: limits).checkWritten(audited, sourceBytes: sourceBytes) {
            throw v
        }
        return audited
    }

    /// `lstat`-style walk (symlinks are reported, never followed), one entry at a time.
    private static func walk(_ root: URL, _ visit: (URL, URLResourceValues) throws -> Void) throws {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .fileSizeKey, .isDirectoryKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: []) else { return }
        while let url = e.nextObject() as? URL {
            try autoreleasepool {
                let values = try url.resourceValues(forKeys: keys)
                try visit(url, values)
                if values.isSymbolicLink == true {
                    e.skipDescendants()
                }
            }
        }
    }
}
