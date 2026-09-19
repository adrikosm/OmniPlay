// OmniPlay bootstrap (isolated world). Typed API only; nothing here evaluates strings from the page.
(() => {
  const VERSION = 1;
  const post = (name, body) => window.webkit?.messageHandlers?.[name]?.postMessage(body);
  const api = {
    version: VERSION,
    profile: __OMNIPLAY_PROFILE__,
    save: {
      write: (key, value) => post("omniplay.save", { op: "write", key: String(key), value: String(value) }),
      read: (key) => post("omniplay.save", { op: "read", key: String(key) }),
      remove: (key) => post("omniplay.save", { op: "remove", key: String(key) }),
    },
    state: {
      report: (path, json) => post("omniplay.state", { path: String(path), json: String(json) }),
    },
    trimCaches: () => { try { window.dispatchEvent(new Event("omniplay:trimcaches")); } catch (_) {} },
    setFrameCap: (fps) => { window.__omniplayFrameCap = Number(fps) || 0; },
    booted: () => post("omniplay.heartbeat", { booted: true, t: Date.now() }),
  };
  Object.freeze(api.save); Object.freeze(api.state); Object.freeze(api);
  window.OmniPlay = api;
  post("omniplay.console", { level: "info", message: "OmniPlay bundle v" + VERSION + " injected" });
})();
