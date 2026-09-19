#if canImport(WebKit) && canImport(UIKit)
    import Foundation

    extension WebRuntime {
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
