// NW.js shims (page world, runs before game scripts). Default: no Node, so MV/MZ take their web path.
(() => {
  const profile = __OMNIPLAY_PROFILE__;
  if (profile.nwUndefined) {
    try { Object.defineProperty(window, "require", { value: undefined, configurable: true, writable: true }); } catch (_) {}
    try { Object.defineProperty(window, "process", { value: undefined, configurable: true, writable: true }); } catch (_) {}
  }
  const shims = new Set(profile.shims || []);
  if (shims.size === 0) return;
  const modules = {};
  if (shims.has("pathPosix")) {
    // POSIX semantics with the game root as the working directory ("/").
    const normalize = (p) => {
      const abs = String(p).startsWith("/"), out = [];
      for (const s of String(p).split("/")) {
        if (s === "..") { if (out.length && out[out.length - 1] !== "..") out.pop(); else if (!abs) out.push(s); }
        else if (s && s !== ".") out.push(s);
      }
      const body = out.join("/") + (out.length && /\/$/.test(String(p)) ? "/" : "");
      return (abs ? "/" : "") + body || (abs ? "/" : ".");
    };
    const trim = (p) => String(p).replace(/(.)\/+$/, "$1");
    const resolve = (...p) => normalize(p.reduce((a, s) => (String(s).startsWith("/") ? s : a + "/" + s), "/")).replace(/(.)\/$/, "$1");
    modules.path = {
      normalize, resolve,
      join: (...p) => normalize(p.join("/")),
      dirname: (p) => { const s = trim(p); return s.includes("/") ? s.replace(/\/[^/]*$/, "") || "/" : "."; },
      basename: (p, ext) => { const b = trim(p).split("/").pop(); return ext && b !== ext && b.endsWith(ext) ? b.slice(0, -ext.length) : b; },
      extname: (p) => { const m = /\.[^./]+$/.exec(p); return m ? m[0] : ""; },
      isAbsolute: (p) => String(p).startsWith("/"),
      relative: (from, to) => {
        const a = resolve(from).split("/").filter(Boolean), b = resolve(to).split("/").filter(Boolean);
        let i = 0;
        while (i < a.length && a[i] === b[i]) i++;
        return [...a.slice(i).map(() => ".."), ...b.slice(i)].join("/");
      },
      sep: "/", delimiter: ":",
    };
    modules.path.parse = (p) => {
      const s = trim(p), base = s.split("/").pop(), ext = modules.path.extname(base);
      const dir = s.includes("/") ? s.replace(/\/[^/]*$/, "") || "/" : "";
      return { root: s.startsWith("/") ? "/" : "", dir, base, ext, name: base.slice(0, base.length - ext.length) };
    };
    modules.path.format = (o) => (o.dir ? o.dir + "/" : o.root || "") + (o.base || (o.name || "") + (o.ext || ""));
    modules.path.posix = modules.path;
  }
  if (shims.has("fsReadOnly")) {
    // Read-only, over the game's own server: a path relative to the working directory (the game root, where NW.js
    // starts) or absolute from it becomes a same-origin URL, so nothing outside the game can be named. Synchronous
    // requests, because the desktop calls are; plugins read their CSV and text tables this way at boot.
    const url = (p, query) => new URL(String(p).replace(/\\/g, "/").split("/").map(encodeURIComponent).join("/") + (query || ""),
      location.origin + "/").href;
    const request = (p, method, query, bytes) => {
      const xhr = new XMLHttpRequest();
      xhr.open(method, url(p, query), false);
      if (bytes) xhr.overrideMimeType("text/plain; charset=x-user-defined");
      try { xhr.send(); } catch (_) { return { status: 0 }; }
      return xhr;
    };
    const enoent = (p) => Object.assign(new Error("ENOENT: no such file or directory, '" + p + "'"), { code: "ENOENT" });
    // The server answers 200 for a file and 403 for a folder.
    const statSync = (p) => {
      const xhr = request(p, "HEAD");
      if (xhr.status !== 200 && xhr.status !== 403) throw enoent(p);
      const file = xhr.status === 200, size = file ? Number(xhr.getResponseHeader("Content-Length")) || 0 : 0;
      return { isFile: () => file, isDirectory: () => !file, isSymbolicLink: () => false, size, mtime: new Date(0), mtimeMs: 0 };
    };
    const readFileSync = (p, options) => {
      const encoding = typeof options === "string" ? options : options && options.encoding;
      const xhr = request(p, "GET", "", !encoding);
      if (xhr.status !== 200) throw enoent(p);
      if (encoding) return xhr.responseText;
      const text = xhr.responseText, data = new Uint8Array(text.length);
      for (let i = 0; i < text.length; i++) data[i] = text.charCodeAt(i) & 0xff;
      data.toString = (enc) => new TextDecoder(enc === "latin1" || enc === "binary" ? "latin1" : "utf-8").decode(data);
      return data;
    };
    const readdirSync = (p, options) => {
      const xhr = request(String(p).replace(/\/*$/, ""), "GET", "?omniplay=list");
      if (xhr.status !== 200) throw enoent(p);
      const names = JSON.parse(xhr.responseText);
      if (!(options && options.withFileTypes)) return names;
      const base = String(p).replace(/\/*$/, "") + "/";
      return names.map((name) => Object.assign(statSync(base + name), { name }));
    };
    const existsSync = (p) => { try { statSync(p); return true; } catch (_) { return false; } };
    const readOnly = (p) => Object.assign(new Error("EROFS: read-only file system, '" + p + "'"), { code: "EROFS" });
    // Callback forms run the synchronous call on the next turn; `exists` keeps its old one-argument callback.
    const later = (f) => (...a) => {
      const done = typeof a[a.length - 1] === "function" ? a.pop() : () => {};
      setTimeout(() => { let r; try { r = f(...a); } catch (e) { done(e); return; } done(null, r); }, 0);
    };
    const promised = (f) => (...a) => Promise.resolve().then(() => f(...a));
    modules.fs = {
      existsSync, statSync, lstatSync: statSync, readFileSync, readdirSync,
      exists: (p, done) => setTimeout(() => done && done(existsSync(p)), 0),
      stat: later(statSync), lstat: later(statSync), readFile: later(readFileSync), readdir: later(readdirSync),
      promises: { stat: promised(statSync), lstat: promised(statSync), readFile: promised(readFileSync), readdir: promised(readdirSync) },
      // Saves go through OmniPlay's storage; a plugin's own file writes fail the way a locked disk does.
      writeFileSync: (p) => { throw readOnly(p); }, mkdirSync: () => {}, unlinkSync: () => {},
    };
  }
  if (shims.has("greenworks")) modules.greenworks = { init: () => false, initAPI: () => false };
  // No `versions.node`: emscripten builds (MZ's vorbisdecoder.js) read that as Node and stop decoding audio. The
  // fields stock MV/MZ code reads once `process` is an object (main.js's mainModule check) are present. Bundled
  // libraries ask for it as a module too (pino's `require('process').mainModule`).
  const process = {
    versions: { nw: "0.0.0" }, platform: "ios", env: {}, argv: [],
    mainModule: { filename: decodeURIComponent(location.pathname) },
    cwd: () => "/", on: () => process,
  };
  if (shims.has("processVersions")) {
    try { Object.defineProperty(window, "process", { value: process, configurable: true }); } catch (_) {}
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
    modules.process = process;
    // Plugins start programs only on the desktop (open the screenshot folder, an editor in test play). There are no
    // processes here: every call fails the way a missing program does, callbacks hear so once, and nothing throws at
    // load time, so the plugin's other features keep working.
    const noProcess = (name) => Object.assign(new Error("child_process." + name + " is not available in OmniPlay"), { code: "ENOSYS" });
    const stream = () => lenient({ on() { return this; }, once() { return this; }, setEncoding() { return this; }, pipe: (to) => to });
    const deadChild = (name, callback) => {
      if (typeof callback === "function") setTimeout(() => callback(noProcess(name), "", ""), 0);
      return lenient({ pid: undefined, exitCode: 1, killed: false, stdout: stream(), stderr: stream(), stdin: stream(),
        kill: () => false, on() { return this; }, once() { return this; } });
    };
    const lastFunction = (args) => [...args].reverse().find((a) => typeof a === "function");
    modules.child_process = {
      exec: (...args) => deadChild("exec", lastFunction(args.slice(1))),
      execFile: (...args) => deadChild("execFile", lastFunction(args.slice(1))),
      spawn: () => deadChild("spawn"),
      fork: () => deadChild("fork"),
      execSync: () => { throw noProcess("execSync"); },
      execFileSync: () => { throw noProcess("execFileSync"); },
      spawnSync: () => ({ pid: 0, status: null, signal: null, output: [], stdout: "", stderr: "", error: noProcess("spawnSync") }),
    };
    // What bundled Node libraries bind at load time; they only reach for more on desktop-only paths.
    modules.util = {
      promisify: (f) => (...a) => new Promise((ok, no) => f(...a, (e, v) => (e ? no(e) : ok(v)))),
      inherits: (c, p) => { Object.setPrototypeOf(c.prototype, p.prototype); Object.setPrototypeOf(c, p); },
      format: (...a) => a.map(String).join(" "), inspect: (v) => { try { return JSON.stringify(v); } catch (_) { return String(v); } },
      deprecate: (f) => f, types: {}, TextEncoder, TextDecoder,
    };
    modules.os = { platform: () => "ios", type: () => "Darwin", homedir: () => "/", tmpdir: () => "/tmp", hostname: () => "iPhone", EOL: "\n" };
    window.require = (name) => { const m = modules[String(name).replace(/^node:/, "")]; if (!m) throw new Error("Cannot find module '" + name + "'"); return m; };
  }
})();
