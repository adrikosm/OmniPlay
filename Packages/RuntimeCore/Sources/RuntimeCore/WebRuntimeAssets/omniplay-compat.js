// RPG Maker MV/MZ compatibility patches (page world), applied once the engine's globals exist.
(() => {
  const profile = __OMNIPLAY_PROFILE__;
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
    if (typeof SceneManager !== "undefined" && SceneManager.run && !SceneManager.__omniplayBooted) {
      SceneManager.__omniplayBooted = true;
      try { document.dispatchEvent(new Event("omniplay:booted")); } catch (_) {}
    }
  };
  document.addEventListener("DOMContentLoaded", patch);
  window.addEventListener("load", patch);
  patch();
})();
