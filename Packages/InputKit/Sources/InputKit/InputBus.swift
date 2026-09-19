/// One stream of input for the active runtime. Producers call `send`; the adapter drains `events`.
/// Events are value types and nothing is retained once consumed.
@MainActor
public final class InputBus {
    public let events: AsyncStream<GameInputEvent>
    private let continuation: AsyncStream<GameInputEvent>.Continuation
    /// Optional synchronous tap for consumers that cannot await (the SwiftUI overlay calling the runtime).
    public var onEvent: (@MainActor (GameInputEvent) -> Void)?

    public init() {
        (events, continuation) = AsyncStream.makeStream(of: GameInputEvent.self, bufferingPolicy: .bufferingNewest(256))
    }

    public func send(_ event: GameInputEvent) {
        continuation.yield(event)
        onEvent?(event)
    }

    public func send(_ batch: [GameInputEvent]) { for event in batch {
        send(event)
    } }

    deinit { continuation.finish() }
}
