// Pause semantics (page world). RPG Maker MV/MZ: stop the scene loop and suspend WebAudio. Anything else:
// every AudioContext the page created is suspended and the page sees itself as hidden.
(() => {
  const contexts = new Set();
  const Native = window.AudioContext || window.webkitAudioContext;
  if (Native) {
    const Tracked = function (...args) { const ctx = new Native(...args); contexts.add(ctx); return ctx; };
    Tracked.prototype = Native.prototype;
    window.AudioContext = Tracked;
    if (window.webkitAudioContext) window.webkitAudioContext = Tracked;
  }
  let paused = false;
  const proto = Document.prototype;
  const hidden = Object.getOwnPropertyDescriptor(proto, "hidden"), state = Object.getOwnPropertyDescriptor(proto, "visibilityState");
  try {
    Object.defineProperty(document, "hidden", { configurable: true, get: () => paused || Boolean(hidden?.get?.call(document)) });
    Object.defineProperty(document, "visibilityState", { configurable: true, get: () => (paused ? "hidden" : state?.get?.call(document) ?? "visible") });
  } catch (_) {}
  const call = (fn) => { try { fn(); } catch (_) {} };
  const setPaused = (next) => {
    paused = next;
    call(() => { if (typeof SceneManager !== "undefined") { if (next && typeof SceneManager.stop === "function") SceneManager.stop(); if (!next && typeof SceneManager.resume === "function") SceneManager.resume(); } });
    call(() => { const ctx = typeof WebAudio !== "undefined" && WebAudio._context; if (ctx) next ? ctx.suspend() : ctx.resume(); });
    for (const ctx of contexts) call(() => (next ? ctx.suspend() : ctx.resume()));
    call(() => document.dispatchEvent(new Event("visibilitychange")));
  };
  document.addEventListener("omniplay:pause", () => setPaused(true));
  document.addEventListener("omniplay:resume", () => setPaused(false));
})();
