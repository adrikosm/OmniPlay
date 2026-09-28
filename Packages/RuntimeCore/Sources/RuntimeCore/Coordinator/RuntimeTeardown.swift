import Diagnostics
import Synchronization

/// A stop deadline must not join a child that ignores cancellation. The losing operation may still be
/// inside native code; the coordinator retains its adapter and refuses further launches after a timeout.
enum RuntimeTeardown {
    static func wait(_ operation: @escaping @Sendable () async -> TeardownVerdict) async -> TeardownVerdict {
        let pending = Mutex<CheckedContinuation<TeardownVerdict, Never>?>(nil)
        return await withCheckedContinuation { continuation in
            pending.withLock { $0 = continuation }
            // Independent of the main actor: a blocked engine must not also block its deadline.
            let timer = Task.detached {
                do { try await Task.sleep(for: RuntimeCoordinator.stopTimeout) } catch { return }
                let continuation = pending.withLock { value in
                    defer { value = nil }
                    return value
                }
                if let continuation {
                    OPLog.log(.runtime, .error, "runtime stop timed out; restart required, adapter retained")
                    continuation.resume(returning: .restartRequired)
                }
            }
            Task {
                let verdict = await operation()
                timer.cancel()
                let continuation = pending.withLock { value in
                    defer { value = nil }
                    return value
                }
                continuation?.resume(returning: verdict)
            }
        }
    }
}
