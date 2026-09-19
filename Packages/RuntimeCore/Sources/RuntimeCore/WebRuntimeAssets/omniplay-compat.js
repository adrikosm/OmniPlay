// RPG Maker MV/MZ compatibility patches (page world), applied once the engine's globals exist.
(() => {
  const profile = __OMNIPLAY_PROFILE__;
  if (profile.devicePixelRatio) {
    try { Object.defineProperty(window, "devicePixelRatio", { configurable: true, get: () => profile.devicePixelRatio }); } catch (_) {}
  }

  // MZ keeps every bitmap forever; large titles then hit the WebContent memory cap. This LRU evicts the least
  // recently used non-system bitmaps once the estimated total passes the cap. Any failure disables it for the page.
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
        const bitmap = IM._cache[url];
        order.delete(url); total -= bytes;
        delete IM._cache[url];
        try { if (bitmap && typeof bitmap.destroy === "function") bitmap.destroy(); } catch (_) {}
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

  const patch = () => {
    if (typeof Utils !== "undefined") {
      if (profile.canPlayWebmFalse && Utils.canPlayWebm) Utils.canPlayWebm = () => false;
      if (Utils.isMobileDevice) Utils.isMobileDevice = () => true;
    }
    if (typeof Graphics !== "undefined" && Graphics.canPlayVideoType) {
      const orig = Graphics.canPlayVideoType.bind(Graphics);
      Graphics.canPlayVideoType = (t) => !/webm/i.test(t) && orig(t);
    }
    if (profile.isGameActivePatch && typeof SceneManager !== "undefined") SceneManager.isGameActive = () => true;
    if (profile.audioFileExtOgg && typeof AudioManager !== "undefined") AudioManager.audioFileExt = () => ".ogg";
    installImageCache();
    if (typeof SceneManager !== "undefined" && SceneManager.run && !SceneManager.__omniplayBooted) {
      SceneManager.__omniplayBooted = true;
      try { document.dispatchEvent(new Event("omniplay:booted")); } catch (_) {}
    }
  };
  let tries = 0;
  const timer = setInterval(() => { patch(); if ((window.ImageManager && window.ImageManager.__omniplayLRU) || ++tries > 600) clearInterval(timer); }, 50);
  document.addEventListener("DOMContentLoaded", patch);
  window.addEventListener("load", patch);
  patch();
})();
