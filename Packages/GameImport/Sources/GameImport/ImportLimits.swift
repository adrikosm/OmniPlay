/// Limits every extractor and content installer enforces (design authority §13.3). Archive headers lie;
/// every limit is enforced against bytes actually written.
public struct SafetyLimits: Sendable, Equatable {
    public var maxUncompressedBytes: UInt64 = 16 << 30
    /// Abort if any single entry exceeds this ratio. Tunable per format (RPA/RGSSAD compress well).
    public var maxEntryCompressionRatio: Double = 200
    public var maxOverallCompressionRatio: Double = 100
    /// Ratios are only judged once this many bytes are involved: tiny archives of stubs or zero-filled
    /// assets legitimately compress thousands to one, while a bomb keeps growing past the floor.
    public var minBytesForRatioCheck: Int64 = 64 << 20
    public var maxEntries: Int = 500_000
    public var maxPathBytes: Int = 1024
    public var maxPathComponents: Int = 64
    /// SFX → CAB → zip is real; anything deeper is not.
    public var maxNestedArchives: Int = 2

    public init() {}

    public static let `default` = SafetyLimits()
}
