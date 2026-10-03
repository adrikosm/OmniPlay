#if canImport(UIKit)
    import Diagnostics
    import Foundation
    import GameCore
    import InputKit
    import OverlayVFS
    import RuntimeCore
    import SaveKit
    import UIKit

    /// The Game Tools' view of a Ren'Py game: store variables, persistent data and labels, answered by the engine's
    /// `base/omniplay_state.py` between interactions (and while paused).
    extension RenPyRuntime: StateInspecting {
        public var stateCapabilities: StateCapabilities { StateCapabilities.renpy.union(.slots) }

        public func inspect(_ request: StateInspectionRequest) async throws -> StateInspectionResult {
            guard let body = StateWire.request(request) else { throw StateBridgeError.engine("not a Ren'Py target") }
            let reply = try await send(body)
            if let error = StateWire.error(in: reply) {
                throw error
            }
            return StateWire.inspectionResult(reply, for: request)
        }

        public func mutate(_ mutation: StateMutation) async -> StateMutationResult {
            guard let body = StateWire.mutationRequest(mutation) else { return .rejected(mutation, "not a Ren'Py target") }
            do {
                let reply = try await send(body)
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

        func send(_ body: [String: Any]) async throws -> [String: Any] {
            guard let library else { throw StateBridgeError.notInGame }
            let data = try JSONSerialization.data(withJSONObject: body)
            guard data.count <= 256 << 10, let json = String(data: data, encoding: .utf8) else {
                throw StateBridgeError.engine("request too large")
            }
            let text = try await library.stateRequest(json)
            guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
                throw StateBridgeError.engine("unreadable reply")
            }
            return object
        }
    }

    /// Ren'Py has no frame pacing to speed up; "faster" is its own skipping, the same as holding Ctrl, labelled Skip.
    extension RenPyRuntime: FastForwardCapable {
        public var speedChoices: SpeedChoices {
            SpeedChoices(title: "Skip", options: [
                .init(value: 1, label: "Off"), .init(value: 2, label: "Seen text"), .init(value: 3, label: "All text"),
            ])
        }

        public func setFastForward(_ mode: Int) {
            fastForward = mode
            // `_preferences` is the player's own, saved with the game: the value before the first change is kept in
            // persistent and put back when Skip goes off (omniplay_host.rpy shares the record with its switch).
            let keep = "if persistent._omniplay_skip_unseen is None: persistent._omniplay_skip_unseen = _preferences.skip_unseen\n"
            let code = switch mode {
            case 2: keep + "_preferences.skip_unseen = False\nrenpy.config.skipping = 'slow'"
            case 3: keep + "_preferences.skip_unseen = True\nrenpy.config.skipping = 'slow'"
            default: """
                if persistent._omniplay_skip_unseen is not None and not __import__("omniplay_host").switches().get("skipUnseen"):
                    _preferences.skip_unseen = persistent._omniplay_skip_unseen
                    persistent._omniplay_skip_unseen = None
                renpy.config.skipping = None
                """
            }
            Task {
                let reply = try? await send(["op": "exec", "code": code])
                OPLog.log(.runtime, .info, "renpy skip mode \(mode): \(reply?["ok"] as? Bool == true ? "set" : "refused")")
            }
        }
    }

    /// Ren'Py Tools' console: Python in the game's store, answered between interactions like every state request.
    extension RenPyRuntime: SlotEditing {
        /// Answered before the load happens: Ren'Py loads by unwinding the interaction, after the reply is out.
        public func loadSlot(file: String) async throws {
            if let error = try await StateWire.error(in: send(["op": "loadSlot", "file": file])) {
                throw error
            }
        }

        public func saveSlot(file: String) async throws {
            if let error = try await StateWire.error(in: send(["op": "saveSlot", "file": file])) {
                throw error
            }
        }
    }

    extension RenPyRuntime: ScriptConsole {
        public func runScript(_ code: String, execute: Bool) async throws -> ScriptResult {
            let reply = try await send(["op": execute ? "exec" : "eval", "code": code])
            if let error = StateWire.error(in: reply) {
                throw error
            }
            return ScriptResult(ok: reply["ok"] as? Bool ?? false, output: reply["output"] as? String ?? "")
        }
    }

    /// TRANS-006: every half second the host's translations go into the game and the lines it missed come out,
    /// through the same mailbox as every state request, answered between interactions, running or paused.
    extension RenPyRuntime: LiveTranslationHost {
        public func deliverTranslations(_ translations: [String: String]) {
            liveOut.merge(translations) { _, new in new }
        }

        func startLivePoll() {
            livePoll?.cancel()
            guard onMissedText != nil else { return }
            livePoll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self, !self.stopping else { return }
                    let out = liveOut
                    liveOut = [:]
                    guard let reply = try? await send(["op": "liveTranslation", "deliver": out]) else {
                        liveOut.merge(out) { current, _ in current }
                        continue
                    }
                    for text in reply["missed"] as? [String] ?? [] {
                        onMissedText?(text)
                    }
                }
            }
        }
    }
#endif
