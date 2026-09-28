#if canImport(WebKit) && canImport(UIKit)
    import Diagnostics
    import Foundation
    import GameCore
    import InputKit
    import LocalGameServer
    import OverlayVFS
    import SaveKit
    import UIKit
    import WebKit

    extension WebRuntime {
        /// Suspension tears sockets down, so saves are flushed first and the listener is rebound on return.
        func observeLifecycle() {
            let center = NotificationCenter.default
            lifecycleObservers = [
                center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.hostWillResignActive() }
                },
                center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.hostDidBecomeActive() }
                },
            ]
        }

        func hostWillResignActive() {
            backgrounded = true
            updatePauseState()
            lifecycleTask?.cancel()
            let task = UIApplication.shared.beginBackgroundTask(withName: "omniplay.autosave") {}
            lifecycleTask = Task { @MainActor [weak self] in
                defer { UIApplication.shared.endBackgroundTask(task) }
                guard !Task.isCancelled, let self, !stopping else { return }
                await autosave()
            }
        }

        func hostDidBecomeActive() {
            backgrounded = false
            lifecycleTask?.cancel()
            lifecycleTask = Task { @MainActor [weak self] in
                guard let self, !stopping else { return }
                if let server {
                    do {
                        let restarted = try await server.restartIfNeeded()
                        guard !Task.isCancelled, !stopping, !backgrounded else { return }
                        if restarted != port {
                            port = restarted
                            OPLog.log(
                                .web,
                                .default,
                                "loopback port changed after background; reloading page",
                                session: configuration?.sessionID
                            )
                            if let url = URL(string: "http://127.0.0.1:\(port)/\(entryPage)") {
                                webView?.load(URLRequest(url: url))
                            }
                        }
                    } catch {
                        guard !Task.isCancelled, !stopping else { return }
                        OPLog.log(.web, .error, "loopback restart failed: \(error)", session: configuration?.sessionID)
                        onFailure?("The game's local server could not restart after returning from the background.")
                        return
                    }
                }
                updatePauseState()
            }
        }

        // MARK: Events

        func handle(_ event: MessageBridge.Event) {
            switch event {
            case .heartbeat: _ = watchdog.handle(.heartbeat, now: .now)
            case .booted:
                _ = watchdog.handle(.pageBooted, now: .now)
                host?.runtimeDidEmit(.gradeReached(.intro))
            case let .console(level, message):
                host?.runtimeDidEmit(.log(.javascript, "[\(level)] \(message)"))
                if let consoleSink {
                    let stamp = Date.now
                        .formatted(.iso8601.year().month().day().timeZone(separator: .omitted).time(includingFractionalSeconds: true))
                    Task { await consoleSink.append("\(stamp)\t\(level)\t\(message)") }
                }
            case let .navigationFailed(detail):
                onFailure?("The game page failed to load: \(detail)")
            case .processTerminated:
                terminations += 1
                writeTermination()
                act(watchdog.handle(.terminated, now: .now))
            case let .missedText(text):
                onMissedText?(text)
            case let .saveFailed(detail):
                onSaveFailure?(detail)
            }
        }

        /// `termination.json`: why the page vanished, for the diagnostics bundle.
        func writeTermination() {
            guard let configuration else { return }
            let record: [String: Any] = [
                "at": Date.now.formatted(.iso8601),
                "count": terminations,
                "hostFootprintBytes": ProcessFootprint.current.map(Int.init) ?? -1,
                "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
                "reason": "WebContent process terminated",
            ]
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: configuration.logDirectory.appending(path: "termination.json"), options: .atomic)
            }
        }

        func act(_ action: WebProcessWatchdog.Action) {
            switch action {
            case .none: break
            case let .reloadAndAutoload(reason):
                OPLog.log(.web, .error, "web process lost: \(reason); reloading", session: configuration?.sessionID)
                onNotice?("The game stopped and was reloaded. Continue from your last save.")
                webView?.reload()
            case let .giveUp(reason):
                onFailure?(reason)
            }
        }
    }

    extension WebRuntime: ScreenCapturing {
        /// WebKit draws the page fresh, paused or not.
        public func captureScreen() async -> CGImage? {
            guard let webView else { return nil }
            return await withCheckedContinuation { continuation in
                webView.takeSnapshot(with: nil) { image, _ in continuation.resume(returning: image?.cgImage) }
            }
        }
    }

    /// RPG Maker MV/MZ state through `omniplay-state.js` in the page world, where `$game*` lives. Other web games
    /// have no typed state and answer `.engine`.
    extension WebRuntime: StateInspecting {
        public var stateCapabilities: StateCapabilities { hasTypedState ? .rpgMaker : [] }

        var hasTypedState: Bool {
            configuration.map { [.rpgMakerMV, .rpgMakerMZ].contains($0.descriptor.engine) } ?? false
        }

        func call(_ request: [String: Any]) async throws -> [String: Any] {
            guard hasTypedState, let webView else { throw StateBridgeError.engine("this game has no typed state") }
            let reply = try await webView.callAsyncJavaScript(
                "return window.__omniplayState ? window.__omniplayState(request) : {error: 'bridge not loaded'};",
                arguments: ["request": request],
                in: nil,
                contentWorld: .page
            )
            guard let object = reply as? [String: Any] else { throw StateBridgeError.engine("unexpected reply") }
            if let error = StateWire.error(in: object) {
                throw error
            }
            return object
        }

        public func inspect(_ request: StateInspectionRequest) async throws -> StateInspectionResult {
            guard let body = StateWire.request(request) else { throw StateBridgeError.engine("not a web target") }
            return try await StateWire.inspectionResult(call(body), for: request)
        }

        public func mutate(_ mutation: StateMutation) async -> StateMutationResult {
            guard let body = StateWire.mutationRequest(mutation) else { return .rejected(mutation, "not a web target") }
            do {
                return try await StateWire.mutationResult(call(body), for: mutation)
            } catch StateBridgeError.notInGame {
                return .rejected(mutation, "The game has not started yet.")
            } catch {
                return .rejected(mutation, String(describing: error))
            }
        }
    }
#endif
