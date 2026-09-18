/// Parsed engine version plus the raw string it came from (detectors keep both; buckets use the numbers).
public struct EngineVersion: Codable, Sendable, Hashable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var raw: String

    public init(major: Int, minor: Int = 0, patch: Int = 0, raw: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.raw = raw ?? "\(major).\(minor).\(patch)"
    }

    /// Leading `major.minor.patch` from strings like `1.6.2`, `8.1.3.23090501`, `v4.7.2-stable`.
    public init?(parsing text: String) {
        let digits = text.drop { !$0.isNumber }
        let parts = digits.split(whereSeparator: { !$0.isNumber }).prefix(3).compactMap { Int($0) }
        guard let major = parts.first else { return nil }
        self.init(major: major, minor: parts.count > 1 ? parts[1] : 0, patch: parts.count > 2 ? parts[2] : 0, raw: text)
    }

    public var description: String { raw }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// The version bucket that decides which embedded runtime a title needs.
public enum EngineGeneration: String, Codable, Sendable, CaseIterable, Hashable {
    case rgss1, rgss2, rgss3
    case renpyPy27, renpyPy39, renpyPy312
    case godot4x
    case mv, mz
}
