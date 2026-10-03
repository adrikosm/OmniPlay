import Darwin
import Foundation
import GameCore
import OSLog

public enum MemoryPressureLevel: String, Codable, Sendable, Hashable {
    case normal, warning, critical
}

public struct MemorySample: Codable, Sendable, Hashable {
    public let timestamp: Date
    /// `phys_footprint`: the number Xcode's memory gauge and jetsam use.
    public let footprintBytes: UInt64?
    public let residentBytes: UInt64?
    /// `os_proc_available_memory()`, iOS only.
    public let availableBytes: UInt64?
    public let pressureLevel: MemoryPressureLevel
    public let label: String
}

public enum MemoryProbe {
    private static let warnedOnce = OSAllocatedUnfairLock(initialState: false)

    public static func sample(label: String, pressure: MemoryPressureLevel = .normal) -> MemorySample {
        let footprint = ProcessFootprint.current
        let resident = ProcessFootprint.resident
        if footprint == nil, !warnedOnce.withLock({ let w = $0; $0 = true; return w }) {
            OPLog.log(.memory, .error, "task_info(TASK_VM_INFO) failed")
        }
        var available: UInt64?
        #if os(iOS)
            available = UInt64(os_proc_available_memory())
        #endif
        return MemorySample(
            timestamp: .now,
            footprintBytes: footprint,
            residentBytes: resident,
            availableBytes: available,
            pressureLevel: pressure,
            label: label
        )
    }

    /// Current `phys_footprint`, for before/after assertions.
    public static var footprint: UInt64 { sample(label: "").footprintBytes ?? 0 }
}

/// Appends JSON lines to `memory.jsonl`, at most one per second and 10 000 per session.
public actor MemoryRecorder {
    public static let maxLines = 10000
    public nonisolated let fileURL: URL
    private let encoder = JSONEncoder()
    private var lines = 0
    private var lastWrite = Date.distantPast
    private var handle: FileHandle?

    public init(fileURL: URL) {
        self.fileURL = fileURL
        encoder.dateEncodingStrategy = .iso8601
    }

    /// Returns false when the sample was dropped by the rate or line cap.
    @discardableResult
    public func record(_ sample: MemorySample, force: Bool = false) -> Bool {
        guard lines < Self.maxLines, force || sample.timestamp.timeIntervalSince(lastWrite) >= 1 else { return false }
        do {
            if handle == nil {
                handle = try FileHandle.appending(to: fileURL).0
            }
            try handle?.write(contentsOf: encoder.encode(sample) + Data([UInt8(ascii: "\n")]))
            lines += 1
            lastWrite = sample.timestamp
            return true
        } catch {
            OPLog.log(.memory, .error, "memory.jsonl write failed: \(error.localizedDescription)")
            return false
        }
    }

    public func close() {
        try? handle?.close()
        handle = nil
    }
}

/// Publishes `.warning` / `.critical` / `.normal` from the kernel's memory-pressure source.
public enum MemoryPressureMonitor {
    public static func levels() -> AsyncStream<MemoryPressureLevel> {
        AsyncStream { continuation in
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
            source.setEventHandler {
                let e = source.data
                continuation.yield(e.contains(.critical) ? .critical : e.contains(.warning) ? .warning : .normal)
            }
            continuation.onTermination = { _ in source.cancel() }
            source.activate()
        }
    }
}
