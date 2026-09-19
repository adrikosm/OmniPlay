// OmniPlay bootstrap (isolated world). Typed API only; nothing here evaluates strings from the page.
// Page-world scripts reach this world through DOM events carrying JSON strings; those are parsed, never evaluated.
(() => {
  const VERSION = 3;
  const post = (name, body) => window.webkit?.messageHandlers?.[name]?.postMessage(body);
  const api = {
    version: VERSION,
    profile: __OMNIPLAY_PROFILE__,
    save: {
      write: (key, value) => post("omniplay.save", { op: "write", kind: "ls", key: String(key), value: String(value) }),
      remove: (key) => post("omniplay.save", { op: "remove", kind: "ls", key: String(key) }),
    },
    state: {
      report: (path, json) => post("omniplay.state", { path: String(path), json: String(json) }),
    },
    trimCaches: () => { try { document.dispatchEvent(new Event("omniplay:trimcaches")); } catch (_) {} },
    setFrameCap: (fps) => { window.__omniplayFrameCap = Number(fps) || 0; },
    booted: () => post("omniplay.heartbeat", { booted: true, t: Date.now() }),
  };
  Object.freeze(api.save); Object.freeze(api.state); Object.freeze(api);
  window.OmniPlay = api;
  document.addEventListener("omniplay:storage", (e) => {
    let msg;
    try { msg = JSON.parse(String(e.detail)); } catch (_) { return; }
    if (!msg || typeof msg !== "object") return;
    post("omniplay.save", { op: String(msg.op), kind: String(msg.kind), key: String(msg.key), value: msg.value == null ? null : String(msg.value) });
  });
  document.addEventListener("omniplay:booted", () => api.booted());
  post("omniplay.console", { level: "info", message: "OmniPlay bundle v" + VERSION + " injected" });
})();
