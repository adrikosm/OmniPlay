// Save routing (page world, document start). Files under Saves/slots are the durable copy; web storage is a mirror.
// localStorage (RPG Maker MV and plain HTML5 games) is seeded from the injected map and every write is echoed to the
// host through a DOM event, which the isolated world forwards. RPG Maker MZ keeps its saves in memory here and the
// host file, bypassing IndexedDB so a rotated loopback port never loses a save.
(() => {
  const saves = __OMNIPLAY_SAVES__;
  let nextID = 0;
  let tail = Promise.resolve();
  let failure = null;
  const replies = new Map();
  document.addEventListener("omniplay:storage-reply", (event) => {
    let reply;
    try { reply = JSON.parse(String(event.detail)); } catch (_) { return; }
    const finish = replies.get(reply.id);
    if (finish) finish(reply.error);
  });
  // One write at a time preserves order and applies backpressure at the native actor.
  const emit = (msg) => {
    const result = tail.then(() => new Promise((resolve, reject) => {
      const id = String(++nextID);
      const timer = setTimeout(() => finish("Save acknowledgement timed out"), 10000);
      const finish = (error) => {
        if (!replies.delete(id)) return;
        clearTimeout(timer);
        error ? reject(new Error(error)) : resolve();
      };
      replies.set(id, finish);
      try { document.dispatchEvent(new CustomEvent("omniplay:storage", { detail: JSON.stringify({ ...msg, id }) })); }
      catch (error) { finish(String(error)); }
    }));
    tail = result.catch((error) => { failure = error; console.error("OmniPlay save failed:", error); });
    return result;
  };
  window.__omniplayFlushSaves = async () => {
    let pending;
    do { pending = tail; await pending; } while (tail !== pending);
    if (failure) { const error = failure; failure = null; throw error; }
  };

  // --- localStorage mirror ---
  try {
    const proto = Storage.prototype;
    const setItem = proto.setItem, removeItem = proto.removeItem, clear = proto.clear;
    const ls = window.localStorage;
    // The host's files are the durable copy. WebKit keeps this origin's storage between launches too, so anything
    // here that the files do not hold (a write that failed, a save deleted or restored since) goes before seeding.
    clear.call(ls);
    for (const [key, value] of Object.entries(saves.ls || {})) setItem.call(ls, key, value);
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
    // Property writes (localStorage.score = 3, delete localStorage.score) skip setItem; they take the same path.
    const proxy = new Proxy(ls, {
      get: (target, prop) => { const v = Reflect.get(target, prop); return typeof v === "function" ? v.bind(target) : v; },
      set: (target, prop, value) => (typeof prop === "string" ? (target.setItem(prop, value), true) : Reflect.set(target, prop, value)),
      deleteProperty: (target, prop) => (typeof prop === "string" ? (target.removeItem(prop), true) : Reflect.deleteProperty(target, prop)),
    });
    Object.defineProperty(window, "localStorage", { configurable: true, get: () => proxy });
  } catch (cause) {
    // A quota/security error must not expose a partial seed that the game can overwrite as a new game.
    const blocked = new Error("OmniPlay could not load all saved web storage. Your save files have been kept.");
    failure = blocked;
    console.error(blocked.message, cause);
    Object.defineProperty(window, "localStorage", { configurable: true, get: () => { throw blocked; } });
    document.addEventListener("DOMContentLoaded", () => {
      document.dispatchEvent(new Event("omniplay:storage-load-failed"));
    }, { once: true });
  }

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
      return emit({ op: "write", kind: "mz", key: k, value: btoa(zip) }).then(() => { mz[k] = zip; });
    };
    SM.loadZip = (name) => { const k = key(name); return k in mz ? Promise.resolve(mz[k]) : origLoad(name); };
    SM.exists = (name) => key(name) in mz || origExists(name);
    SM.remove = (name) => {
      const k = key(name);
      return emit({ op: "remove", kind: "mz", key: k }).then(() => {
        delete mz[k];
        return Promise.resolve(origRemove(name));
      });
    };
    return true;
  };
  // --- RPG Maker MV StorageManager ---
  // MV picks file saves when Utils.isNwjs(), which the NW.js shims make true for games with Node plugins; its file
  // path needs process.mainModule and a writable fs, so every save threw. MV saves always go to web storage, which
  // the wrapper above routes to the game's Saves/.
  const patchMV = () => {
    const SM = window.StorageManager;
    if (!SM || SM.__omniplayMV || typeof SM.saveToWebStorage !== "function") return false;
    SM.__omniplayMV = true;
    SM.isLocalMode = () => false;
    return true;
  };
  const patch = () => patchMZ() || patchMV();
  let tries = 0;
  const timer = setInterval(() => { if (patch() || ++tries > 600) clearInterval(timer); }, 50);
  document.addEventListener("DOMContentLoaded", patch);
  window.addEventListener("load", patch);
})();
