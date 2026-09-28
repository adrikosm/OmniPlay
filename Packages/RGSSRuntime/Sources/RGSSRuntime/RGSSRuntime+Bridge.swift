#if canImport(UIKit)
    import CMkxpBridge
    import Diagnostics
    import Foundation
    import GameCore
    import InputKit
    import RuntimeCore
    import SaveKit
    import UIKit

    // MARK: Engine-thread entry points

    //
    // These fire on the engine's own threads. Each one only forwards; `hop` moves the work to the main actor.

    func rgssEngineTerminated(_ userdata: UnsafeMutableRawPointer?) {
        hop(userdata) { $0.engineTerminated() }
    }

    func rgssEngineError(_ message: UnsafePointer<CChar>?, _ userdata: UnsafeMutableRawPointer?) {
        let text = message.map { String(cString: $0) } ?? "engine error"
        hop(userdata) { $0.engineError(text) }
    }

    func rgssEngineInfo(_ message: UnsafePointer<CChar>?, _ userdata: UnsafeMutableRawPointer?) {
        let text = message.map { String(cString: $0) } ?? ""
        hop(userdata) { $0.engineInfo(text) }
    }

    /// Trampoline for the engine's C callbacks: they fire on the engine thread, so every one hops to the main
    /// actor before touching the adapter. Unretained on purpose — the adapter outlives its own callbacks.
    func hop(_ userdata: UnsafeMutableRawPointer?, _ body: @escaping @MainActor (RGSSRuntime) -> Void) {
        guard let userdata else { return }
        let runtime = Unmanaged<RGSSRuntime>.fromOpaque(userdata).takeUnretainedValue()
        Task { @MainActor in body(runtime) }
    }

    /// Typed state through `omniplay_bridge.rb` on the engine thread (mkxp-z patch 0002): the request waits in the
    /// engine's queue until its next frame, so a paused game answers `timedOut`, never hangs the caller.
    extension RGSSRuntime: SlotEditing {
        public func loadSlot(file: String) async throws {
            if let error = try await StateWire.error(in: RubyRequest.send(["op": "loadSlot", "file": file])) {
                throw error
            }
        }

        public func saveSlot(file: String) async throws {
            if let error = try await StateWire.error(in: RubyRequest.send(["op": "saveSlot", "file": file])) {
                throw error
            }
        }
    }

    extension RGSSRuntime: StateInspecting {
        public var stateCapabilities: StateCapabilities { StateCapabilities.rpgMaker.union(.slots) }

        public func inspect(_ request: StateInspectionRequest) async throws -> StateInspectionResult {
            guard let body = StateWire.request(request) else { throw StateBridgeError.engine("not an RGSS target") }
            let reply = try await RubyRequest.send(body)
            if let error = StateWire.error(in: reply) {
                throw error
            }
            return StateWire.inspectionResult(reply, for: request)
        }

        public func mutate(_ mutation: StateMutation) async -> StateMutationResult {
            guard let body = StateWire.mutationRequest(mutation) else { return .rejected(mutation, "not an RGSS target") }
            do {
                let reply = try await RubyRequest.send(body)
                if let error = StateWire.error(in: reply) {
                    throw error
                }
                return StateWire.mutationResult(reply, for: mutation)
            } catch StateBridgeError.notInGame {
                return .rejected(mutation, "The game has not started yet.")
            } catch {
                return .rejected(mutation, String(describing: error))
            }
        }
    }

    /// One request's reply, delivered once: by the engine thread's callback or by the timeout, whichever comes first.
    final class RubyRequest: @unchecked Sendable {
        static let timeout: Duration = .seconds(2)
        let lock = NSLock()
        var continuation: CheckedContinuation<String, Error>?

        static func send(_ body: [String: Any]) async throws -> [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: body)
            guard data.count <= 256 << 10, let json = String(data: data, encoding: .utf8) else {
                throw StateBridgeError.engine("request too large")
            }
            let request = RubyRequest()
            let text: String = try await withCheckedThrowingContinuation { continuation in
                request.continuation = continuation
                let context = Unmanaged.passRetained(request).toOpaque()
                mkxp_enqueueRubyRequest(json, { reply, context in
                    guard let context else { return }
                    let request = Unmanaged<RubyRequest>.fromOpaque(context).takeRetainedValue()
                    request.finish(.success(reply.map { String(cString: $0) } ?? ""))
                }, context)
                Task {
                    try? await Task.sleep(for: timeout)
                    request.finish(.failure(StateBridgeError.timedOut))
                }
            }
            guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
                throw StateBridgeError.engine("unreadable reply")
            }
            return object
        }

        func finish(_ result: Result<String, Error>) {
            lock.lock()
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }
#endif
