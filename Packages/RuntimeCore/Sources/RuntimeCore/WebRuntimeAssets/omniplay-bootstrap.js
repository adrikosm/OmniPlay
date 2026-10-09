// OmniPlay bootstrap (isolated world). Typed API only; nothing here evaluates strings from the page.
// Page-world scripts reach this world through DOM events carrying JSON strings; those are parsed, never evaluated.
(() => {
  const VERSION = 5;
  const post = (name, body) => window.webkit?.messageHandlers?.[name]?.postMessage(body);
  const api = {
    version: VERSION,
    profile: __OMNIPLAY_PROFILE__,
    save: {
      write: (key, value) => post("omniplay.save", { op: "write", kind: "ls", key: String(key), value: String(value) }),
      remove: (key) => post("omniplay.save", { op: "remove", kind: "ls", key: String(key) }),
    },
    trimCaches: () => { try { document.dispatchEvent(new Event("omniplay:trimcaches")); } catch (_) {} },
    booted: () => post("omniplay.heartbeat", { booted: true, t: Date.now() }),
  };
  Object.freeze(api.save); Object.freeze(api);
  window.OmniPlay = api;
  // A line the page's dictionary missed, for live translation; plain text, never evaluated.
  document.addEventListener("omniplay:missed", (e) => {
    if (typeof e.detail === "string" && e.detail.length <= 2000) post("omniplay.translate", { text: e.detail });
  });
  document.addEventListener("omniplay:storage", (e) => {
    let msg;
    try { msg = JSON.parse(String(e.detail)); } catch (_) { return; }
    if (!msg || typeof msg !== "object") return;
    const reply = (error) => document.dispatchEvent(new CustomEvent("omniplay:storage-reply", {
      detail: JSON.stringify({ id: msg.id, error: error ? String(error) : null })
    }));
    const response = post("omniplay.save", { op: String(msg.op), kind: String(msg.kind), key: String(msg.key),
      value: msg.value == null ? null : String(msg.value) });
    if (!response || typeof response.then !== "function") reply("Native save acknowledgement is unavailable");
    else response.then(() => reply(null), reply);
  });
  document.addEventListener("omniplay:storage-load-failed", () => {
    post("omniplay.save", { op: "seedFailed", kind: "ls", key: "" })?.catch(() => {});
  });
  // RPG Maker says so when its scene loop starts; any other page has drawn once it has loaded. Once per page.
  let booted = false;
  const bootedOnce = () => { if (!booted) { booted = true; api.booted(); } };
  document.addEventListener("omniplay:booted", bootedOnce);
  window.addEventListener("load", bootedOnce, { once: true });
  // A viewport tag without a width (RPG Maker MV's own template says only "user-scalable=no") makes WebKit lay the
  // page out 980 px wide and zoom it, so the engine fits its canvas to the wrong window and the picture is cropped.
  const fixViewport = (node) => {
    if (node.nodeName !== "META" || node.name !== "viewport" || /width\s*=/.test(node.content)) return;
    node.content = "width=device-width, initial-scale=1" + (node.content ? ", " + node.content : "");
  };
  const viewportWatch = new MutationObserver((records) => records.forEach((r) => r.addedNodes.forEach(fixViewport)));
  viewportWatch.observe(document, { childList: true, subtree: true });
  document.addEventListener("DOMContentLoaded", () => viewportWatch.disconnect(), { once: true });
  post("omniplay.console", { level: "info", message: "OmniPlay bundle v" + VERSION + " injected" });
})();
