// Console and error capture (isolated world): bounded message size and rate.
(() => {
  const post = (body) => window.webkit?.messageHandlers?.["omniplay.console"]?.postMessage(body);
  const MAX = 4096; let count = 0, windowStart = Date.now(), dropped = 0;
  const send = (level, args) => {
    const now = Date.now();
    if (now - windowStart > 1000) { if (dropped) post({ level: "warn", message: `${dropped} console messages dropped` }); count = 0; dropped = 0; windowStart = now; }
    if (++count > 200) { dropped++; return; }
    let text; try { text = args.map((a) => (typeof a === "string" ? a : JSON.stringify(a))).join(" "); } catch (_) { text = String(args); }
    post({ level, message: text.length > MAX ? text.slice(0, MAX) + "…" : text });
  };
  for (const level of ["log", "info", "warn", "error", "debug"]) {
    const orig = console[level];
    console[level] = (...args) => { send(level, args); try { orig.apply(console, args); } catch (_) {} };
  }
  window.addEventListener("error", (e) => send("error", [e.message, e.filename + ":" + e.lineno]));
  window.addEventListener("unhandledrejection", (e) => send("error", ["unhandledrejection", String(e.reason)]));
})();
