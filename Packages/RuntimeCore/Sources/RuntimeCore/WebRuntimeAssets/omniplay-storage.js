// Save routing (page world, document start). Files under Saves/slots are the durable copy; web storage is a mirror.
// localStorage (RPG Maker MV and plain HTML5 games) is seeded from the injected map and every write is echoed to the
// host through a DOM event, which the isolated world forwards. RPG Maker MZ keeps its saves in memory here and the
// host file, bypassing IndexedDB so a rotated loopback port never loses a save.
(() => {
  const saves = __OMNIPLAY_SAVES__;
  const emit = (msg) => {
    try { document.dispatchEvent(new CustomEvent("omniplay:storage", { detail: JSON.stringify(msg) })); } catch (_) {}
  };

  // --- localStorage mirror ---
  try {
    const proto = Storage.prototype;
    const setItem = proto.setItem, removeItem = proto.removeItem, clear = proto.clear;
    const ls = window.localStorage;
    for (const [key, value] of Object.entries(saves.ls || {})) { try { setItem.call(ls, key, value); } catch (_) {} }
    proto.setItem = function (key, value) {
      setItem.call(this, key, value);
      if (this === ls) emit({ op: "write", kind: "ls", key: String(key), value: String(value) });
    };
    proto.removeItem = function (key) {
      removeItem.call(this, key);
      if (this === ls) emit({ op: "remove", kind: "ls", key: String(key) });
    };
    proto.clear = function () {
      const keys = this === ls ? Object.keys(ls) : [];
      clear.call(this);
      for (const key of keys) emit({ op: "remove", kind: "ls", key });
    };
  } catch (_) {}

  // --- RPG Maker MZ StorageManager ---
  const mz = {};
  for (const [key, b64] of Object.entries(saves.mz || {})) { try { mz[key] = atob(b64); } catch (_) {} }
  const patchMZ = () => {
    const SM = window.StorageManager;
    if (!SM || SM.__omniplayPatched || typeof SM.saveZip !== "function") return false;
    SM.__omniplayPatched = true;
    const key = (name) => { try { return SM.forageKey(name); } catch (_) { return "rmmzsave.0." + name; } };
    const origLoad = SM.loadZip.bind(SM), origExists = SM.exists.bind(SM), origRemove = SM.remove.bind(SM);
    SM.saveZip = (name, zip) => {
      const k = key(name);
      mz[k] = zip;
      emit({ op: "write", kind: "mz", key: k, value: btoa(zip) });
      return Promise.resolve();
    };
    SM.loadZip = (name) => { const k = key(name); return k in mz ? Promise.resolve(mz[k]) : origLoad(name); };
    SM.exists = (name) => key(name) in mz || origExists(name);
    SM.remove = (name) => {
      const k = key(name);
      delete mz[k];
      emit({ op: "remove", kind: "mz", key: k });
      return Promise.resolve(origRemove(name)).catch(() => {});
    };
    return true;
  };
  let tries = 0;
  const timer = setInterval(() => { if (patchMZ() || ++tries > 600) clearInterval(timer); }, 50);
  document.addEventListener("DOMContentLoaded", patchMZ);
  window.addEventListener("load", patchMZ);
})();
