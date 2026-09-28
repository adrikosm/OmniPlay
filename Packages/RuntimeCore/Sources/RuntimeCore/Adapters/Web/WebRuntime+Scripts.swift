#if canImport(WebKit) && canImport(UIKit)
    import Foundation
    import WebKit

    extension WebRuntime {
        /// User scripts run again after every navigation, including a WebContent crash reload. Refresh the
        /// host snapshot first, otherwise document-start seeding can resurrect this session's older saves.
        func installScripts(in controller: WKUserContentController) async throws {
            let seed = try await saves?.seed() ?? "{}"
            guard !stopping else { throw CancellationError() }
            let page = try WebRuntimeBundle.pageScripts.map {
                try WKUserScript(
                    source: WebRuntimeBundle.source($0, profile: profile, saves: seed),
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            }
            let isolated = try WebRuntimeBundle.isolatedScripts.map {
                try WKUserScript(
                    source: WebRuntimeBundle.source($0, profile: profile),
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true,
                    in: .world(name: "OmniPlay")
                )
            }
            controller.removeAllUserScripts()
            for script in page + isolated {
                controller.addUserScript(script)
            }
        }

        /// Asks RPG Maker MV/MZ to write the engine's own autosave slot while the page is still alive.
        /// MZ has a real autosave slot (0); MV has none, so slot 99 stands in. Anything else is skipped.
        /// A function body for `callAsyncJavaScript`: the `return` hands back the promise, so the host waits for MZ's
        /// asynchronous save before tearing the page down (without it the result was always "unknown").
        static let autosaveScript = """
        return (async () => {
          try {
            let result = "flushed";
            if (enabled && typeof DataManager !== "undefined" && typeof SceneManager !== "undefined" &&
                typeof $gameMap !== "undefined" && $gameMap && typeof Scene_Map !== "undefined" &&
                SceneManager._scene instanceof Scene_Map) {
              const slot = typeof StorageManager.saveZip === "function" ? 0 : 99;
              if (typeof $gameSystem?.onBeforeSave === "function") $gameSystem.onBeforeSave();
              const saved = await Promise.resolve(DataManager.saveGame(slot));
              if (saved === false) throw new Error("The engine refused the autosave");
              if (typeof StorageManager.saveZip === "function") await DataManager.saveGlobalInfo();
              result = "saved:" + slot;
            }
            if (typeof window.__omniplayFlushSaves !== "function") throw new Error("The save bridge is unavailable");
            await window.__omniplayFlushSaves();
            return result;
          } catch (e) { return "error:" + e; }
        })()
        """

        static func userAgent(_ kind: WebUserAgent) -> String {
            let webkit = "AppleWebKit/605.1.15 (KHTML, like Gecko)"
            switch kind {
            case .iphone:
                return "Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) \(webkit) Version/27.0 Mobile/15E148 Safari/604.1 OmniPlay/1"
            case .ipad: return "Mozilla/5.0 (iPad; CPU OS 27_0 like Mac OS X) \(webkit) Version/27.0 Mobile/15E148 Safari/604.1 OmniPlay/1"
            case .desktop: return "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) \(webkit) Version/27.0 Safari/605.1.15 OmniPlay/1"
            }
        }

        @MainActor final class OutcomeBox { var done = false }
    }
#endif
