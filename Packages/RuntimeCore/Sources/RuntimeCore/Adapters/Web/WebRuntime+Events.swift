#if canImport(WebKit) && canImport(UIKit)
    import Diagnostics
    import Foundation
    import GameCore
    import InputKit
    import LocalGameServer
    import os
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
                        let restarted = try await server.rebind()
                        guard !Task.isCancelled, !stopping, !backgrounded else { return }
                        if restarted != port {
                            port = restarted
                            resumeOnBoot = hasTypedState && resumeSnapshot != nil
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

        func updatePauseState() {
            guard !stopping else { return }
            let paused = userPaused || backgrounded
            _ = watchdog.handle(paused ? .paused : .resumed, now: .now)
            // WebKit's own suspension as well as the page's: a page script that resumes its audio context cannot
            // undo it, so no sound plays on under the pause menu or in the background. On the way back WebKit's ends
            // first: a page resuming its audio inside it was refused, and the game stayed silent.
            if paused {
                dispatch("omniplay:pause")
                webView?.setAllMediaPlaybackSuspended(true)
            } else {
                showPage(true)
                // A second later regardless, in case WebKit never answers (a web process that just ended).
                let resumed = OutcomeBox()
                let resume = { [weak self] in
                    guard let self, !resumed.done, !userPaused, !backgrounded else { return }
                    resumed.done = true
                    dispatch("omniplay:resume")
                }
                webView?.setAllMediaPlaybackSuspended(false) { resume() }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    resume()
                }
            }
        }

        // MARK: Events

        func handle(_ event: MessageBridge.Event) {
            switch event {
            case .heartbeat: _ = watchdog.handle(.heartbeat, now: .now)
            case .booted:
                _ = watchdog.handle(.pageBooted, now: .now)
                host?.runtimeDidEmit(.gradeReached(.intro))
                if fastForward > 1 {
                    dispatch("omniplay:speed", detail: fastForward)
                }
                if resumeOnBoot {
                    resumeOnBoot = false
                    resume(from: resumeSnapshot)
                }
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
            case .probe:
                // A busy page answers when it is free; a dead process answers at once with this error. Only a reply
                // to this probe counts: a heartbeat or a reload in the meantime clears `probed`.
                OPLog.log(.web, .default, "page silent; probing the web process", session: configuration?.sessionID)
                webView?.evaluateJavaScript("0", in: nil, in: .page) { [weak self] result in
                    guard let self, watchdog.probed, case let .failure(error) = result,
                          (error as? WKError)?.code == .webContentProcessTerminated else { return }
                    handle(.processTerminated)
                }
            case let .reloadAndAutoload(reason):
                resumeOnBoot = hasTypedState && resumeSnapshot != nil
                OPLog.log(
                    .web,
                    .error,
                    "web process lost: \(reason); reloading\(resumeOnBoot ? " and resuming" : "")",
                    session: configuration?.sessionID
                )
                onNotice?(
                    resumeOnBoot ? "The game's page stopped. Bringing you back to where you were…"
                        : "The game stopped and was reloaded. Continue from your last save."
                )
                webView?.reload()
            case let .giveUp(reason):
                onFailure?(reason)
            }
        }

        /// Seconds between crash-resume snapshots, in watchdog ticks of two seconds.
        static let snapshotTicks = 6

        /// Keeps the newest snapshot the page offers; it offers none while anything is going on, and the last one
        /// stays. Not while paused or in the background, where the page is stopped.
        func takeSnapshot() async {
            guard hasTypedState, !userPaused, !backgrounded, !stopping, !resumeOnBoot, let webView else { return }
            let reply = try? await webView.callAsyncJavaScript(
                "return (window.__omniplaySnapshot && window.__omniplaySnapshot()) || ''", contentWorld: .page
            )
            guard let json = reply as? String, !json.isEmpty, json.utf8.count <= Self.maxSnapshotBytes,
                  json != resumeSnapshot else { return }
            resumeSnapshot = json
            // On disk too, so a launch after OmniPlay itself was closed mid-game resumes as well (see `prepare`).
            if let file = snapshotFile {
                Task.detached(priority: .utility) {
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? Data(json.utf8).write(to: file, options: .atomic)
                }
            }
        }

        /// The snapshot kept between launches. A clean exit deletes it, so finding it at launch means the last
        /// session ended without one: the app was closed or killed while the game ran.
        var snapshotFile: URL? { configuration?.cacheDirectory.appending(path: "resume-snapshot.json") }

        /// At launch: a snapshot left by a session that never exited cleanly is resumed once the page boots.
        func loadSavedSnapshot() {
            guard hasTypedState, let file = snapshotFile, let data = try? Data(contentsOf: file),
                  let json = String(bytes: data, encoding: .utf8), !json.isEmpty else { return }
            resumeSnapshot = json
            resumeOnBoot = true
            OPLog.log(.web, .default, "last session ended without a clean exit; resuming its snapshot", session: configuration?.sessionID)
        }

        static let maxSnapshotBytes = 16 << 20

        /// Hands the reloaded page the snapshot; it loads it once its boot scene has finished.
        func resume(from snapshot: String?) {
            guard let snapshot, let webView else { return }
            let session = configuration?.sessionID
            webView.callAsyncJavaScript(
                "return window.__omniplayResume ? await window.__omniplayResume(json) : 'no resume bridge'",
                arguments: ["json": snapshot],
                in: nil,
                in: .page
            ) { [weak self] result in
                let outcome = switch result {
                case let .success(value): value as? String ?? "unknown"
                case let .failure(error): "error: \(error.localizedDescription)"
                }
                OPLog.log(.web, outcome == "resumed" ? .info : .error, "crash resume: \(outcome)", session: session)
                self?.onNotice?(
                    outcome == "resumed" ? "You're back where you were." : "The game was reloaded. Continue from your last save."
                )
            }
        }
    }

    extension WebRuntime: ScreenCapturing {
        /// WebKit draws the page fresh, paused or not.
        public func captureScreen(width: CGFloat?) async -> CGImage? {
            guard let webView else { return nil }
            // A small picture is the frame on screen now, not the next one: the paused page may not draw again soon.
            // A page taken out of the window under the pause menu (the screenshot button) is put back and drawn first.
            let wasHidden = webView.window == nil
            showPage(true)
            let config = width.map { width in
                let config = WKSnapshotConfiguration()
                config.snapshotWidth = NSNumber(value: Double(width))
                config.afterScreenUpdates = wasHidden
                return config
            }
            let image = await withCheckedContinuation { continuation in
                webView.takeSnapshot(with: config) { image, _ in continuation.resume(returning: image?.cgImage) }
            }
            // Once the paused frame is taken the page leaves the window until resume (`showPage`).
            if userPaused {
                showPage(false)
            }
            return image
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

    /// Files the loopback server has served, counted from its own threads.
    final class ServedFiles: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (files: 0, bytes: Int64(0)))

        func add(_ bytes: Int64) {
            state.withLock { $0.files += 1; $0.bytes += bytes }
        }

        var total: (files: Int, bytes: Int64) { state.withLock { $0 } }
    }

    extension WebRuntime: WebStorageWriting {
        /// Through the page's own `localStorage`, whose mirror writes the save file and is waited on, so the running
        /// game sees the change at once and never writes the old value back over it.
        public func writeStorage(_ key: String, _ value: String?) async throws {
            guard let webView else { throw StateBridgeError.engine("the game is not running") }
            _ = try await webView.callAsyncJavaScript(
                """
                if (value === null) localStorage.removeItem(key); else localStorage.setItem(key, value);
                await window.__omniplayFlushSaves();
                """,
                arguments: ["key": key, "value": value ?? NSNull()],
                in: nil,
                contentWorld: .page
            )
        }
    }
#endif
