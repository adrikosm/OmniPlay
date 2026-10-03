/// One input path for the active runtime. Producers call `send`; the consumer (the SwiftUI overlay calling the
/// runtime) receives each event synchronously through `onEvent`. Nothing is retained once delivered.
@MainActor
public final class InputBus {
    public var onEvent: (@MainActor (GameInputEvent) -> Void)?

    public init() {}

    public func send(_ event: GameInputEvent) {
        onEvent?(event)
    }

    public func send(_ batch: [GameInputEvent]) { for event in batch {
        send(event)
    } }
}
