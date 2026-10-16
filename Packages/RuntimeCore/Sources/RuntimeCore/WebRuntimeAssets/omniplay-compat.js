// Engine compatibility patches (page world), applied once the engine's globals exist.
(() => {
  const profile = __OMNIPLAY_PROFILE__;
  // Tyrano cancels every touchmove so the page cannot scroll. WebKit then drops the click of any tap whose finger
  // moved at all, and buttons stop answering. The web view never scrolls here, so those cancels are ignored.
  if (profile.ignoreTouchMoveCancel && window.TouchEvent) {
    const cancel = Event.prototype.preventDefault;
    TouchEvent.prototype.preventDefault = function () { if (this.type !== "touchmove") cancel.call(this); };
  }
  if (profile.devicePixelRatio) {
    try { Object.defineProperty(window, "devicePixelRatio", { configurable: true, get: () => profile.devicePixelRatio }); } catch (_) {}
  }

  // Bound MZ's cache references, not live textures: sprites and plugins may still use an evicted bitmap.
  // ponytail: this estimate is not a process/GPU memory cap; profile live ownership before adding stronger eviction.
  const installImageCache = () => {
    const IM = window.ImageManager;
    if (!profile.imageCacheCapMB || !IM || IM.__omniplayLRU || typeof IM.loadBitmapFromUrl !== "function" || !IM._cache) return false;
    const cap = profile.imageCacheCapMB * 1024 * 1024;
    const order = new Map(); // url → estimated bytes, insertion order = recency
    let total = 0;
    const evict = (target) => {
      for (const [url, bytes] of order) {
        if (total <= target) break;
        if (/(^|\/)img\/system\//.test(url)) continue;
        order.delete(url); total -= bytes;
        delete IM._cache[url];
      }
    };
    const original = IM.loadBitmapFromUrl.bind(IM);
    IM.loadBitmapFromUrl = function (url) {
      try {
        if (order.has(url)) { const bytes = order.get(url); order.delete(url); order.set(url, bytes); }
        const bitmap = original(url);
        if (bitmap && !order.has(url)) {
          order.set(url, 0);
          const account = () => {
            const bytes = (bitmap.width || 0) * (bitmap.height || 0) * 4;
            if (order.has(url)) { total += bytes - order.get(url); order.set(url, bytes); }
            if (total > cap) evict(cap);
          };
          if (typeof bitmap.addLoadListener === "function") bitmap.addLoadListener(account); else account();
        }
        return bitmap;
      } catch (err) {
        console.error("OmniPlay image cache wrapper disabled: " + err);
        IM.loadBitmapFromUrl = original;
        return original(url);
      }
    };
    IM.__omniplayLRU = { size: () => total, trim: () => evict(cap / 4) };
    document.addEventListener("omniplay:trimcaches", () => IM.__omniplayLRU.trim());
    return true;
  };

  // TyranoScript desktop builds may save to files through Electron's studio_api (or NW.js fs), which WebKit lacks.
  // Those saves go to web storage instead, which the storage mirror already carries to the host.
  const patchTyrano = () => {
    const $ = window.jQuery;
    if (!$ || $.__omniplayStorage || typeof $.setStorageFile !== "function" || window.studio_api) return;
    $.__omniplayStorage = true;
    for (const [name, typeAt] of [["setStorage", 2], ["getStorage", 1], ["removeStorage", 1]]) {
      const original = $[name];
      if (typeof original !== "function") continue;
      $[name] = function (...args) {
        if (args[typeAt] === "file") args[typeAt] = "webstorage";
        return original.apply(this, args);
      };
    }
  };

  // Fill: MV/MZ scale to cover the screen instead of fitting it. The canvas is placed by pixel offsets, not a
  // transform, because the engines map touches through offsetLeft/offsetTop and _realScale.
  const installFill = () => {
    const G = window.Graphics;
    if (!profile.fill || !G || G.__omniplayFill || typeof G._updateRealScale !== "function" || typeof G._centerElement !== "function") return;
    G.__omniplayFill = true;
    const fit = G._updateRealScale, center = G._centerElement;
    G._updateRealScale = function () {
      fit.call(this);
      if (this._stretchEnabled) this._realScale = Math.max(window.innerWidth / this._width, window.innerHeight / this._height);
    };
    G._centerElement = function (el) {
      center.call(this, el);
      const w = this._width * this._realScale, h = this._height * this._realScale;
      Object.assign(el.style, { margin: "0", right: "auto", bottom: "auto",
        left: (window.innerWidth - w) / 2 + "px", top: (window.innerHeight - h) / 2 + "px" });
    };
    if (typeof G._updateAllElements === "function" && G._canvas) G._updateAllElements();
  };

  // On Mobile Safari MV reads input before each frame, and plugins that replace updateMain (YEP_FpsSynchOption) read
  // it again, which drops every tap and key press. The desktop loop reads it once per update at a fixed 60 Hz.
  const installDesktopLoop = () => {
    const S = window.SceneManager;
    if (typeof Utils === "undefined" || Utils.RPGMAKER_NAME !== "MV" || Utils.__omniplayLoop || !S ||
      typeof S._getTimeInMsWithoutMobileSafari !== "function") return;
    Utils.__omniplayLoop = true;
    Utils.isMobileSafari = () => false;
    // rpg_managers.js starts this clock at load only off Mobile Safari; without it the loop never runs.
    if (typeof S._currentTime !== "number") { S._currentTime = S._getTimeInMsWithoutMobileSafari(); S._accumulator = 0; }
  };

  const patch = () => {
    patchTyrano();
    if (typeof Utils !== "undefined") {
      if (Utils.canPlayWebm) Utils.canPlayWebm = () => false;
      if (Utils.isMobileDevice) Utils.isMobileDevice = () => true;
    }
    if (typeof Graphics !== "undefined" && Graphics.canPlayVideoType && !Graphics.__omniplayVideoType) {
      Graphics.__omniplayVideoType = true;
      const orig = Graphics.canPlayVideoType.bind(Graphics);
      Graphics.canPlayVideoType = (t) => !/webm/i.test(t) && orig(t);
    }
    if (profile.isGameActivePatch && typeof SceneManager !== "undefined") SceneManager.isGameActive = () => true;
    if (profile.audioFileExtOgg && typeof AudioManager !== "undefined") AudioManager.audioFileExt = () => ".ogg";
    installImageCache();
    installFill();
    installDesktopLoop();
    if (typeof SceneManager !== "undefined" && SceneManager.run && !SceneManager.__omniplayBooted) {
      SceneManager.__omniplayBooted = true;
      try { document.dispatchEvent(new Event("omniplay:booted")); } catch (_) {}
    }
  };
  let tries = 0;
  const timer = setInterval(() => { patch(); if ((window.ImageManager && window.ImageManager.__omniplayLRU) || ++tries > 600) clearInterval(timer); }, 50);
  document.addEventListener("DOMContentLoaded", patch);
  window.addEventListener("load", patch);
  // An MV game that asks for the canvas renderer (Community_Basic's renderingMode) draws every sprite on the CPU and
  // crawls on a phone. Plugins set that choice while loading, so it is replaced once they all have, before MV boots.
  window.addEventListener("load", () => {
    const S = window.SceneManager;
    if (typeof Utils === "undefined" || Utils.RPGMAKER_NAME !== "MV" || !S || typeof S.preferableRendererType !== "function") return;
    const pick = S.preferableRendererType;
    S.preferableRendererType = function () { const r = pick.call(this); return r === "canvas" ? "auto" : r; };
  });
  patch();
})();
