// NW.js shims (page world, runs before game scripts). Default: no Node, so MV/MZ take their web path.
(() => {
  const profile = __OMNIPLAY_PROFILE__;
  const post = (name, body) => window.webkit?.messageHandlers?.[name]?.postMessage(body);
  if (profile.nwUndefined) {
    try { Object.defineProperty(window, "require", { value: undefined, configurable: true, writable: true }); } catch (_) {}
    try { Object.defineProperty(window, "process", { value: undefined, configurable: true, writable: true }); } catch (_) {}
  }
  const shims = new Set(profile.shims || []);
  if (shims.size === 0) return;
  const modules = {};
  if (shims.has("pathPosix")) {
    modules.path = {
      join: (...p) => p.join("/").replace(/\/+/g, "/"),
      dirname: (p) => p.replace(/\/[^/]*$/, "") || ".",
      basename: (p, ext) => { const b = p.split("/").pop(); return ext && b.endsWith(ext) ? b.slice(0, -ext.length) : b; },
      extname: (p) => { const m = /\.[^./]+$/.exec(p); return m ? m[0] : ""; },
      resolve: (...p) => p.join("/").replace(/\/+/g, "/"),
      sep: "/",
    };
  }
  if (shims.has("fsReadOnly")) {
    // Read-only, path-confined: every path goes to the host, which serves only logical paths inside the game.
    const deny = (p) => /(^|\/)\.\.(\/|$)|^\//.test(String(p));
    modules.fs = {
      existsSync: (p) => !deny(p) && post("omniplay.fs", { op: "exists", path: String(p) }) !== false,
      readFileSync: (p) => { if (deny(p)) throw new Error("ENOENT"); throw new Error("readFileSync is not available in OmniPlay; assets load over HTTP"); },
      readdirSync: () => [], writeFileSync: () => { throw new Error("EROFS"); }, mkdirSync: () => {}, unlinkSync: () => {},
    };
  }
  if (shims.has("greenworks")) modules.greenworks = { init: () => false, initAPI: () => false };
  if (shims.has("processVersions")) {
    try { Object.defineProperty(window, "process", { value: { versions: { node: "0.0.0", nw: "0.0.0" }, platform: "ios", env: {} }, configurable: true }); } catch (_) {}
  }
  // NW.js's own API. Known properties answer plainly; any other method is a no-op, so start-up code that sizes,
  // moves, titles or decorates the desktop window (MV's SceneManager.initNwjs and plugins that extend it) runs
  // through. `then` stays undefined so these never look like promises.
  const lenient = (base) => new Proxy(base, {
    get: (t, k) => (k in t ? t[k] : typeof k === "string" && k !== "then" && k !== "toJSON" ? () => undefined : undefined),
  });
  const nwWindow = lenient({ width: window.innerWidth, height: window.innerHeight, x: 0, y: 0, menu: null, title: document.title });
  const gui = lenient({
    Window: lenient({ get: () => nwWindow }),
    App: lenient({ argv: [], manifest: {}, quit: () => {} }),
    Menu: function () { return lenient({ items: [] }); },
    MenuItem: function () { return lenient({}); },
    Shell: lenient({}),
  });
  if (shims.has("nwWindow")) {
    window.nw = gui;
  }
  if (Object.keys(modules).length) {
    // Anything that defines require also makes MV's Utils.isNwjs() true, which sends the game to require('nw.gui').
    modules["nw.gui"] = gui;
    window.require = (name) => { const m = modules[String(name).replace(/^node:/, "")]; if (!m) throw new Error("Cannot find module '" + name + "'"); return m; };
  }
})();
