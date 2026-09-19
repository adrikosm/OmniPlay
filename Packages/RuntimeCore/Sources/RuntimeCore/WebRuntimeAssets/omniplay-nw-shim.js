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
  if (shims.has("nwWindow")) {
    window.nw = { Window: { get: () => ({ on: () => {}, maximize: () => {}, enterFullscreen: () => {}, leaveFullscreen: () => {}, showDevTools: () => {}, close: () => {}, width: window.innerWidth, height: window.innerHeight }) }, App: { argv: [], quit: () => {} } };
  }
  if (Object.keys(modules).length) {
    window.require = (name) => { const m = modules[String(name).replace(/^node:/, "")]; if (!m) throw new Error("Cannot find module '" + name + "'"); return m; };
  }
})();
