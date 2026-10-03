import Diagnostics
import Synchronization

/// A stop deadline must not join a child that ignores cancellation. The losing operation may still be
/// inside native code; the coordinator retains its adapter and refuses further launches after a timeout.
enum RuntimeTeardown {
    static func wait(
        timeout: Duration = RuntimeCoordinator.stopTimeout,
        _ operation: @escaping @Sendable () async -> TeardownVerdict
    ) async -> TeardownVerdict {
        let pending = Mutex<CheckedContinuation<TeardownVerdict, Never>?>(nil)
        let take: @Sendable () -> CheckedContinuation<TeardownVerdict, Never>? = { pending.withLock { value in
            defer { value = nil }
            return value
        } }
        return await withCheckedContinuation { continuation in
            pending.withLock { $0 = continuation }
            // Independent of the main actor: a blocked engine must not also block its deadline.
            let timer = Task.detached {
                do { try await Task.sleep(for: timeout) } catch { return }
                if let continuation = take() {
                    OPLog.log(.runtime, .error, "runtime stop timed out; restart required, adapter retained")
                    continuation.resume(returning: .restartRequired)
                }
            }
            Task {
                let verdict = await operation()
                timer.cancel()
                take()?.resume(returning: verdict)
            }
        }
    }
}
