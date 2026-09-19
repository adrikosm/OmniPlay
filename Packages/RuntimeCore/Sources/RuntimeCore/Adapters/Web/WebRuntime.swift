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

    /// One WKWebView per game, fed by a loopback server over the overlay VFS, with an isolated script world,
    /// typed message handlers and a heartbeat watchdog. Everything is torn down in `stop`.
    @MainActor
    public final class WebRuntime: NSObject, GameRuntime {
        public static let runtimeID = RuntimeIdentifier.web
        public let capabilities = RuntimeCapabilities(
            canInspectState: false,
            canMutateState: false,
            pause: .backgroundVisible,
            multiSession: true
        )
        public let renderSurface = RuntimeSurface.webView

        public enum Failure: Error { case notPrepared, navigation(String), injection(String) }

        private var configuration: RuntimeConfiguration?
        private var profile = WebProfile()
        private var server: HTTPServer?
        private var port: UInt16 = 0
        private var webView: WKWebView?
        private var handler: MessageBridge?
        private var saves: SaveBridge?
        private var watchdog = WebProcessWatchdog(now: .now)
        private var watchdogTask: Task<Void, Never>?
        private weak var host: (any RuntimeHost)?
        public var onFailure: (@MainActor (String) -> Void)?
        public var onNotice: (@MainActor (String) -> Void)?

        override public init() { super.init() }

        /// Builds the resolver over the game's layers and starts the loopback server on the game's remembered port.
        public func prepare(configuration: RuntimeConfiguration) async throws {
            self.configuration = configuration
            profile = WebProfile.derive(from: configuration.descriptor)
            let location = SaveLocation(savesRoot: configuration.saveDirectory.deletingLastPathComponent())
            try location.ensure()
            try SaveVault.writeProvenance(
                game: configuration.game,
                titleHash: configuration.descriptor.identityHash,
                engine: configuration.descriptor.engine,
                location: location
            )
            saves = SaveBridge(location: location, engine: configuration.descriptor.engine, session: configuration.sessionID)
            let index = try PathIndex.open(at: configuration.indexURL)
            let resolver = OverlayResolver(layers: configuration.layers, index: index)
            let entry = configuration.entryPoint ?? "index.html"
            let router = GameFileRouter(resolver: resolver, policy: profile.headerPolicy, defaultDocument: entry)
            let server = HTTPServer(router: router)
            let remembered = configuration.profile.overrides["loopbackPort"].flatMap(UInt16.init)
            port = try await server.start(port: remembered)
            if let remembered, remembered != port {
                OPLog.log(
                    .web,
                    .default,
                    "loopback port changed \(remembered) → \(port); web storage origin changes",
                    session: configuration.sessionID
                )
            }
            self.server = server
        }

        public func start(in host: any RuntimeHost) async throws {
            guard let configuration, server != nil else { throw Failure.notPrepared }
            self.host = host
            let config = WKWebViewConfiguration()
            config.websiteDataStore = WKWebsiteDataStore(forIdentifier: configuration.game.rawValue)
            config.allowsInlineMediaPlayback = true
            config.mediaTypesRequiringUserActionForPlayback = []
            config.preferences.isElementFullscreenEnabled = false
            config.defaultWebpagePreferences.allowsContentJavaScript = true
            let world = WKContentWorld.world(name: "OmniPlay")
            let bridge = MessageBridge(session: configuration.sessionID) { [weak self] event in self?.handle(event) }
            handler = bridge
            for name in MessageBridge.handlers {
                config.userContentController.add(bridge, contentWorld: world, name: name)
            }
            do {
                let seed = saves?.seed() ?? "{}"
                for name in WebRuntimeBundle.pageScripts {
                    try config.userContentController.addUserScript(WKUserScript(
                        source: WebRuntimeBundle.source(name, profile: profile, saves: seed),
                        injectionTime: .atDocumentStart,
                        forMainFrameOnly: true
                    ))
                }
                for name in WebRuntimeBundle.isolatedScripts {
                    try config.userContentController.addUserScript(WKUserScript(
                        source: WebRuntimeBundle.source(name, profile: profile),
                        injectionTime: .atDocumentStart,
                        forMainFrameOnly: true,
                        in: world
                    ))
                }
            } catch {
                throw Failure.injection(String(describing: error))
            }
            let webView = WKWebView(frame: host.containerView.bounds, configuration: config)
            webView.translatesAutoresizingMaskIntoConstraints = false
            webView.isOpaque = false
            webView.backgroundColor = .black
            webView.scrollView.isScrollEnabled = false
            webView.scrollView.contentInsetAdjustmentBehavior = .never
            webView.navigationDelegate = bridge
            webView.customUserAgent = Self.userAgent(profile.userAgent)
            host.containerView.addSubview(webView)
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: host.containerView.topAnchor),
                webView.bottomAnchor.constraint(equalTo: host.containerView.bottomAnchor),
                webView.leadingAnchor.constraint(equalTo: host.containerView.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: host.containerView.trailingAnchor),
            ])
            self.webView = webView
            let entry = configuration.entryPoint ?? "index.html"
            guard let url = URL(string: "http://127.0.0.1:\(port)/\(entry)") else { throw Failure.navigation("bad entry \(entry)") }
            OPLog.log(.web, .info, "loading \(url) bundle v\(WebRuntimeBundle.version)", session: configuration.sessionID)
            webView.load(URLRequest(url: url))
            watchdog = WebProcessWatchdog(now: .now)
            watchdogTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard let self else { return }
                    act(watchdog.tick(now: .now))
                }
            }
        }

        public func pause() async {
            _ = watchdog.handle(.paused, now: .now)
            webView?.evaluateJavaScript("document.dispatchEvent(new Event('visibilitychange'))", in: nil, in: .page) { _ in }
        }

        public func resume() async {
            _ = watchdog.handle(.resumed, now: .now)
            if let server {
                _ = try? await server.start(port: port)
            }
        }

        public func send(_ input: GameInputEvent) {
            // INPUT-002 wires the DOM dispatch; touches reach the web view natively.
        }

        public func inspect(_: StateInspectionRequest) async throws -> StateInspectionResult { throw Failure.notPrepared }
        public func mutate(_: StateMutation) async throws -> StateMutationResult { throw Failure.notPrepared }
        public func saveSnapshot() async throws -> SaveSnapshot {
            guard let saves, let configuration else { throw Failure.notPrepared }
            return try await SaveVault.snapshot(
                location: saves.location,
                identityHash: configuration.descriptor.identityHash,
                reason: .manualSnapshot
            )
        }

        /// Asks RPG Maker MV/MZ to write the engine's own autosave slot while the page is still alive.
        /// MZ has a real autosave slot (0); MV has none, so slot 99 stands in. Anything else is skipped.
        static let autosaveScript = """
        (async () => {
          try {
            if (typeof DataManager === "undefined" || typeof SceneManager === "undefined") return "no-engine";
            if (typeof $gameMap === "undefined" || !$gameMap) return "no-engine";
            if (!(SceneManager._scene instanceof Scene_Map)) return "not-on-map";
            const slot = typeof StorageManager.saveZip === "function" ? 0 : 99;
            if (typeof $gameSystem?.onBeforeSave === "function") $gameSystem.onBeforeSave();
            await Promise.resolve(DataManager.saveGame(slot));
            return "saved:" + slot;
          } catch (e) { return "error:" + e; }
        })()
        """

        private func autosave() async {
            guard let webView, profile.autosaveOnExit else { return }
            let box = OutcomeBox()
            let result = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                let finish: @MainActor (String) -> Void = { outcome in
                    guard !box.done else { return }
                    box.done = true
                    continuation.resume(returning: outcome)
                }
                webView.callAsyncJavaScript(Self.autosaveScript, in: nil, in: .page) { outcome in
                    switch outcome {
                    case let .success(value): finish(value as? String ?? "unknown")
                    case let .failure(error): finish("error: \(error.localizedDescription)")
                    }
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    finish("timeout")
                }
            }
            OPLog.log(.save, .info, "autosave on exit: \(result)", session: configuration?.sessionID)
        }

        @MainActor private final class OutcomeBox { var done = false }

        public func handleMemoryPressure(_ level: MemoryPressureLevel) {
            guard level == .critical else { return }
            webView?.evaluateJavaScript("window.OmniPlay && OmniPlay.trimCaches()", in: nil, in: .world(name: "OmniPlay")) { _ in }
        }

        public func handleThermalState(_ state: ProcessInfo.ThermalState) {
            guard state == .serious || state == .critical else { return }
            webView?.evaluateJavaScript("window.OmniPlay && OmniPlay.setFrameCap(30)", in: nil, in: .world(name: "OmniPlay")) { _ in }
        }

        /// Removes handlers and scripts, blanks the page, detaches the view, stops the server.
        public func stop(reason: RuntimeStopReason) async -> TeardownVerdict {
            watchdogTask?.cancel()
            watchdogTask = nil
            if reason == .userExit || reason == .memoryPressure || reason == .switchingGame {
                await autosave()
            }
            if let webView {
                let controller = webView.configuration.userContentController
                for name in MessageBridge.handlers {
                    controller.removeScriptMessageHandler(
                        forName: name,
                        contentWorld: .world(name: "OmniPlay")
                    )
                }
                controller.removeAllUserScripts()
                webView.stopLoading()
                webView.navigationDelegate = nil
                webView.loadHTMLString("", baseURL: nil)
                webView.removeFromSuperview()
            }
            webView = nil
            handler = nil
            await server?.stop()
            server = nil
            OPLog.log(.web, .info, "web runtime stopped (\(reason))", session: configuration?.sessionID)
            return .clean
        }

        // MARK: Events

        private func handle(_ event: MessageBridge.Event) {
            switch event {
            case .heartbeat: _ = watchdog.handle(.heartbeat, now: .now)
            case .booted:
                _ = watchdog.handle(.pageBooted, now: .now)
                host?.runtimeDidEmit(.gradeReached(.intro))
            case let .console(level, message):
                host?.runtimeDidEmit(.log(.javascript, "[\(level)] \(message)"))
            case let .navigationFailed(detail):
                onFailure?("The game page failed to load: \(detail)")
            case .processTerminated:
                act(watchdog.handle(.terminated, now: .now))
            case let .save(op, kind, key, value):
                saves?.handle(op: op, kind: kind, key: key, value: value)
                host?.runtimeDidEmit(.log(.save, "\(op) \(kind) \(key) \(value?.count ?? 0) bytes"))
            }
        }

        private func act(_ action: WebProcessWatchdog.Action) {
            switch action {
            case .none: break
            case let .reloadAndAutoload(reason):
                OPLog.log(.web, .error, "web process lost: \(reason); reloading", session: configuration?.sessionID)
                onNotice?("The game was reloaded to free memory.")
                webView?.reload()
            case let .giveUp(reason):
                onFailure?(reason)
            }
        }

        static func userAgent(_ kind: WebUserAgent) -> String {
            let webkit = "AppleWebKit/605.1.15 (KHTML, like Gecko)"
            switch kind {
            case .iphone:
                return "Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) \(webkit) Version/27.0 Mobile/15E148 Safari/604.1 OmniPlay/1"
            case .ipad: return "Mozilla/5.0 (iPad; CPU OS 27_0 like Mac OS X) \(webkit) Version/27.0 Mobile/15E148 Safari/604.1 OmniPlay/1"
            case .desktop: return "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) \(webkit) Version/27.0 Safari/605.1.15 OmniPlay/1"
            }
        }
    }

    /// Receives typed messages from the isolated world and navigation callbacks; never evaluates page strings.
    @MainActor
    final class MessageBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let handlers = ["omniplay.console", "omniplay.save", "omniplay.heartbeat", "omniplay.state", "omniplay.fs"]

        enum Event {
            case heartbeat, booted, console(level: String, message: String), navigationFailed(String), processTerminated
            case save(op: String, kind: String, key: String, value: String?)
        }

        private let session: SessionID
        private let onEvent: @MainActor (Event) -> Void

        init(session: SessionID, onEvent: @escaping @MainActor (Event) -> Void) {
            self.session = session
            self.onEvent = onEvent
        }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            let body = message.body as? [String: Any] ?? [:]
            switch message.name {
            case "omniplay.heartbeat": onEvent(body["booted"] as? Bool == true ? .booted : .heartbeat)
            case "omniplay.console":
                let level = (body["level"] as? String ?? "log").prefix(8)
                let text = (body["message"] as? String ?? "").prefix(4096)
                OPLog.log(.javascript, level == "error" ? .error : .debug, "\(text)", session: session)
                onEvent(.console(level: String(level), message: String(text)))
            case "omniplay.save":
                onEvent(.save(
                    op: body["op"] as? String ?? "",
                    kind: body["kind"] as? String ?? "ls",
                    key: (body["key"] as? String ?? "").prefix(256).description,
                    value: body["value"] as? String
                ))
            default: break
            }
        }

        func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: any Error) {
            onEvent(.navigationFailed(error.localizedDescription))
        }

        func webViewWebContentProcessDidTerminate(_: WKWebView) { onEvent(.processTerminated) }
    }
#endif
