// Pause semantics (page world). RPG Maker MV/MZ: stop the scene loop and suspend WebAudio. Anything else:
// every AudioContext the page created is suspended and the page sees itself as hidden.
(() => {
  const contexts = new Set();
  const Native = window.AudioContext || window.webkitAudioContext;
  if (Native) {
    const Tracked = function (...args) {
      const ctx = new Native(...args);
      contexts.add(ctx);
      if (paused) ctx.suspend();
      return ctx;
    };
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
    if (paused === next) return;
    paused = next;
    call(() => {
      if (typeof SceneManager === "undefined") return;
      const S = SceneManager;
      if (next && typeof S.stop === "function") S.stop();
      // Older MV has stop() but no resume(); its loop ends once stopped, so it is restarted by hand.
      else if (!next && typeof S.resume === "function") S.resume();
      else if (!next && S._stopped && typeof S.requestUpdate === "function") { S._stopped = false; S.requestUpdate(); }
    });
    const rpg = typeof WebAudio !== "undefined" && WebAudio._context;
    for (const ctx of rpg ? [rpg, ...contexts] : contexts) call(() => (next ? ctx.suspend() : wake(ctx)));
    call(() => document.dispatchEvent(new Event("visibilitychange")));
    if (!next) restoreMasterVolume();
  };
  // A resume can be refused while iOS is still bringing the app's audio back; it is asked again until it runs.
  const wake = (ctx, tries = 0) => {
    if (paused || ctx.state === "running" || ctx.state === "closed") return;
    ctx.resume().catch(() => {});
    if (tries < 15) setTimeout(() => wake(ctx, tries + 1), 300);
  };
  // RPG Maker MV/MZ fade the master volume out when the page hides and in when it shows, without clearing the earlier
  // fade. With the audio clock stopped in between (pause, the background), the fade-out ended after the fade-in and
  // the game stayed silent until it was reloaded. On the way back the fades are cleared and the game's volume is set.
  const restoreMasterVolume = () => call(() => {
    const WA = window.WebAudio, gain = WA && WA._masterGainNode && WA._masterGainNode.gain, ctx = WA && WA._context;
    if (!gain || !ctx || paused) return;
    gain.cancelScheduledValues(0);
    gain.setValueAtTime(WA._masterVolume ?? 1, ctx.currentTime);
  });
  // The system's own hide and show (the app leaving and coming back) runs the same fades.
  document.addEventListener("visibilitychange", () => {
    if (!paused && !document.hidden) setTimeout(restoreMasterVolume, 0);
  });
  // Speed (RPG Maker): MZ asks determineRepeatNumber how many updates a frame needs, so that is scaled. MV has no such
  // hook: its scene runs extra updates, each after a fresh input read so one press never triggers twice.
  let speed = 1;
  const installSpeed = () => {
    const S = window.SceneManager;
    if (!S || S.__omniplaySpeed || typeof S.updateScene !== "function") return;
    S.__omniplaySpeed = true;
    if (typeof S.determineRepeatNumber === "function") {
      const repeat = S.determineRepeatNumber;
      S.determineRepeatNumber = function (dt) { return repeat.call(this, dt) * speed; };
    } else {
      const update = S.updateScene;
      S.updateScene = function () {
        update.call(this);
        for (let i = 1; i < speed; i++) { this.updateInputData(); this.changeScene(); update.call(this); }
      };
    }
  };
  document.addEventListener("omniplay:speed", (e) => { speed = Math.max(1, e.detail | 0); call(installSpeed); });
  // A page reloaded while the host is paused (WebContent crash) starts paused; RPG Maker's scene is stopped once it runs.
  if (__OMNIPLAY_PROFILE__.paused) {
    paused = true;
    const wait = setInterval(() => {
      if (!paused) return clearInterval(wait);
      if (window.SceneManager?._scene) { clearInterval(wait); paused = false; setPaused(true); }
    }, 100);
  }
  document.addEventListener("omniplay:pause", () => setPaused(true));
  document.addEventListener("omniplay:resume", () => setPaused(false));
})();
