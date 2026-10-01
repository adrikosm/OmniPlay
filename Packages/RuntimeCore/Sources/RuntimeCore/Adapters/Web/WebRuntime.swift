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
    public final class WebRuntime: NSObject, GameRuntime, FastForwardCapable, LiveTranslationHost {
        public enum Failure: Error { case notPrepared, navigation(String), injection(String) }

        var configuration: RuntimeConfiguration?
        var profile = WebProfile()
        var server: HTTPServer?
        var port: UInt16 = 0
        var webView: WKWebView?
        var handler: MessageBridge?
        var saves: SaveBridge?
        var saveTask: Task<String, Never>?
        var pendingInput: [GameInputEvent] = []
        var lifecycleObservers: [any NSObjectProtocol] = []
        var lifecycleTask: Task<Void, Never>?
        var userPaused = false
        var backgrounded = false
        var stopping = false
        var consoleSink: FileLogSink?
        var terminations = 0
        var inputFlushScheduled = false
        var watchdog = WebProcessWatchdog(now: .now)
        var watchdogTask: Task<Void, Never>?
        weak var host: (any RuntimeHost)?
        public var onFailure: (@MainActor (String) -> Void)?
        public var onNotice: (@MainActor (String) -> Void)?
        public var onSaveFailure: (@MainActor (String) -> Void)?

        /// Drops a deleted game's WebKit storage (its per-game data store).
        public static func removeData(for game: GameID) async {
            // remove(forIdentifier:) answers on WebKit's main run loop, which only exists once WebKit is set up; in a
            // launch that has not shown a web game yet it crashed the app. Any data store sets WebKit up.
            _ = WKWebsiteDataStore.default()
            try? await WKWebsiteDataStore.remove(forIdentifier: game.rawValue)
        }

        public var onMissedText: (@MainActor (String) -> Void)?

        override public init() { super.init() }

        /// The page the web view opens: the game's own entry, or the KrKr2 Web engine's for a KiriKiri game.
        var entryPage: String {
            profile.kirikiri ? KiriKiriWeb.entry(startup: configuration?.entryPoint) : configuration?.entryPoint ?? "index.html"
        }

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
            let plan = MediaPlan(requirements: configuration.descriptor.mediaRequirements)
            var layers = configuration.layers
            if profile.kirikiri {
                guard let engine = KiriKiriWeb.engineRoot() else { throw Failure.navigation("this build has no KrKr2 Web engine") }
                try index.rebuild(layer: KiriKiriWeb.layerName, root: engine)
                layers.append(KiriKiriWeb.layer(root: engine))
            }
            let resolver = OverlayResolver(layers: layers, index: index, aliases: plan.aliases)
            if !plan.aliases.isEmpty {
                OPLog.log(.media, .info, "\(plan.aliases.count) media aliases installed", session: configuration.sessionID)
            }
            var router = GameFileRouter(resolver: resolver, policy: profile.headerPolicy, defaultDocument: entryPage)
            // WebKit decodes no Ogg Vorbis; omniplay-audio.js routes it here (see OggVorbisDecoder).
            let vorbis = OggVorbisDecoder(cacheDirectory: configuration.cacheDirectory, session: configuration.sessionID)
            router.postRoutes[OggVorbisDecoder.postPath] = { request in await vorbis.respond(to: request) }
            router.transforms["pcm"] = { file in await vorbis.transform(file) }
            router.siblingExtensions = WebProfile.mediaSiblings
            if profile.kirikiri, let game = configuration.layers.first(where: { $0.tier == .original })?.root {
                for (path, route) in KiriKiriWeb.routes(
                    gameRoot: game,
                    saves: configuration.saveDirectory,
                    session: configuration.sessionID
                ) {
                    router.postRoutes[path] = route
                }
            }
            // Files converted before launch because WebKit cannot play them (AppModel+Media).
            if let json = configuration.profile.overrides["mediaRemap"]?.data(using: .utf8),
               let remap = try? JSONDecoder().decode([String: String].self, from: json) {
                router.aliases = remap
            }
            // The active MTool dictionary, from its pack's layer, for omniplay-translate.js.
            if let dictionary = configuration.profile.overrides["translationDictionary"] {
                router.aliases["omniplay-translation.json"] = dictionary
            }
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
            host.runtimeDidEmit(.profileHint(key: "loopbackPort", value: String(port)))
            let config = WKWebViewConfiguration()
            config.websiteDataStore = WKWebsiteDataStore(forIdentifier: configuration.game.rawValue)
            config.allowsInlineMediaPlayback = true
            config.mediaTypesRequiringUserActionForPlayback = []
            config.preferences.isElementFullscreenEnabled = false
            config.defaultWebpagePreferences.allowsContentJavaScript = true
            let world = WKContentWorld.world(name: "OmniPlay")
            let bridge = MessageBridge(session: configuration.sessionID, saves: saves) { [weak self] event in self?.handle(event) }
            bridge.prepareNavigation = { [weak self] webView in
                guard let self, !stopping else { throw CancellationError() }
                guard webView.url != nil else { return } // The initial seed is installed before the web view exists.
                try await installScripts(in: webView.configuration.userContentController)
            }
            handler = bridge
            for name in MessageBridge.handlers {
                if name == "omniplay.save" {
                    config.userContentController.addScriptMessageHandler(bridge, contentWorld: world, name: name)
                } else {
                    config.userContentController.add(bridge, contentWorld: world, name: name)
                }
            }
            try await installScripts(in: config.userContentController)
            let webView = WKWebView(frame: host.containerView.bounds, configuration: config)
            webView.translatesAutoresizingMaskIntoConstraints = false
            webView.isOpaque = false
            webView.backgroundColor = .black
            webView.scrollView.isScrollEnabled = profile.pageScroll
            webView.scrollView.bounces = false
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
            let entry = entryPage
            guard let url = URL(string: "http://127.0.0.1:\(port)/\(entry)") else { throw Failure.navigation("bad entry \(entry)") }
            OPLog.log(.web, .info, "loading \(url) bundle v\(WebRuntimeBundle.version)", session: configuration.sessionID)
            webView.load(URLRequest(url: url))
            consoleSink = FileLogSink(directory: configuration.logDirectory, stem: "web-console", maxFileBytes: 4 << 20)
            observeLifecycle()
            watchdog = WebProcessWatchdog(now: .now)
            watchdogTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let self else { return }
                    act(watchdog.tick(now: .now))
                }
            }
        }

        public func pause() async {
            userPaused = true
            updatePauseState()
        }

        func updatePauseState() {
            guard !stopping else { return }
            let paused = userPaused || backgrounded
            _ = watchdog.handle(paused ? .paused : .resumed, now: .now)
            dispatch(paused ? "omniplay:pause" : "omniplay:resume")
        }

        public func resume() async {
            userPaused = false
            updatePauseState()
        }

        // ponytail: a page reload (watchdog) drops back to 1x in the page while this still reports the old speed.
        public private(set) var fastForward = 1

        public func setFastForward(_ multiplier: Int) {
            fastForward = max(1, min(8, multiplier))
            webView?.callAsyncJavaScript(
                "document.dispatchEvent(new CustomEvent('omniplay:speed', { detail: n }))",
                arguments: ["n": fastForward],
                in: nil,
                in: .page
            ) { _ in }
        }

        /// RPG Maker's scene loop can be sped up; other web games pace themselves, so they get no speed row.
        public var speedChoices: SpeedChoices { profile.rpgMaker ? .multipliers : SpeedChoices(title: "", options: []) }

        /// Translations for lines the page asked about; it shows them from the next time each line is drawn.
        public func deliverTranslations(_ translations: [String: String]) {
            guard !translations.isEmpty else { return }
            webView?.callAsyncJavaScript(
                "document.dispatchEvent(new CustomEvent('omniplay:translated', { detail: map }))",
                arguments: ["map": translations],
                in: nil,
                in: .page
            ) { _ in }
        }

        /// Fires a plain DOM event in the page world; the page scripts do the engine-specific work.
        func dispatch(_ name: String) {
            webView?.callAsyncJavaScript(
                "document.dispatchEvent(new Event(name))",
                arguments: ["name": name],
                in: nil,
                in: .page
            ) { _ in }
        }

        /// Batched per frame: one script call carries every event queued since the last flush.
        public func send(_ input: GameInputEvent) {
            pendingInput.append(input)
            guard !inputFlushScheduled else { return }
            inputFlushScheduled = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(16))
                self?.flushInput()
            }
        }

        func flushInput() {
            inputFlushScheduled = false
            guard !pendingInput.isEmpty, let webView else { pendingInput.removeAll(); return }
            let batch = WebInputEncoder.json(pendingInput)
            pendingInput.removeAll(keepingCapacity: true)
            webView.callAsyncJavaScript(
                "document.dispatchEvent(new CustomEvent('omniplay:input', { detail: batch }))",
                arguments: ["batch": batch],
                in: nil,
                in: .page
            ) { _ in }
        }

        func autosave() async {
            if let saveTask {
                _ = await saveTask.value; return
            }
            guard let webView else { return }
            let enabled = profile.autosaveOnExit
            let task = Task { @MainActor in
                let box = OutcomeBox()
                return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                    let finish: @MainActor (String) -> Void = { outcome in
                        guard !box.done else { return }
                        box.done = true
                        continuation.resume(returning: outcome)
                    }
                    webView.callAsyncJavaScript(Self.autosaveScript, arguments: ["enabled": enabled], in: nil, in: .page) { outcome in
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
            }
            saveTask = task
            let result = await task.value
            saveTask = nil
            OPLog.log(.save, .info, "autosave on exit: \(result)", session: configuration?.sessionID)
            if result == "timeout" || result.hasPrefix("error:") {
                // The reason (the host's or the page's) is in the log line above; the player gets the gist.
                onSaveFailure?("The last save could not be confirmed, so recent progress may be missing.")
            }
        }

        public func handleMemoryPressure(_ level: MemoryPressureLevel) {
            guard level == .critical else { return }
            webView?.evaluateJavaScript("window.OmniPlay && OmniPlay.trimCaches()", in: nil, in: .world(name: "OmniPlay")) { _ in }
        }

        /// Removes handlers and scripts, blanks the page, detaches the view, stops the server.
        public func stop(reason: RuntimeStopReason) async -> TeardownVerdict {
            stopping = true
            lifecycleTask?.cancel()
            lifecycleTask = nil
            watchdogTask?.cancel()
            watchdogTask = nil
            lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
            lifecycleObservers = []
            if let consoleSink {
                await consoleSink.close()
            }
            consoleSink = nil
            if reason == .userExit || reason == .memoryPressure || reason == .switchingGame || reason == .hostShutdown {
                await autosave()
            }
            // The dictionary's hit and miss counts go in the session log, which Diagnostics shows (TRANS-003).
            // Optional diagnostics must never hold teardown hostage to an unresponsive page.
            let sessionID = configuration?.sessionID
            webView?.callAsyncJavaScript(
                "const s = window.__omniplayTranslation; return s && (s.entries || s.misses) ? JSON.stringify(s) : null",
                in: nil, in: .page
            ) { result in
                if case let .success(stats as String) = result {
                    OPLog.log(.web, .info, "translation this session: \(stats)", session: sessionID)
                }
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
            saves = nil
            pendingInput.removeAll()
            onMissedText = nil
            await server?.stop()
            server = nil
            OPLog.log(.web, .info, "web runtime stopped (\(reason))", session: configuration?.sessionID)
            return .clean
        }
    }
#endif
