// The game's own console and errors (page world). The capture that writes web-console.log lives in the isolated
// world, whose console is a different object, so page messages cross over as JSON strings in a DOM event.
(() => {
  const forward = (level, args) => {
    let text;
    try {
      text = args.map((a) => (typeof a === "string" ? a : a instanceof Error ? (a.stack || String(a)) : JSON.stringify(a))).join(" ");
    } catch (_) { text = String(args); }
    try { document.dispatchEvent(new CustomEvent("omniplay:console", { detail: JSON.stringify({ level, message: text.slice(0, 4096) }) })); } catch (_) {}
  };
  for (const level of ["log", "info", "warn", "error", "debug"]) {
    const orig = console[level];
    console[level] = function (...args) { forward(level, args); return orig.apply(console, args); };
  }
  window.addEventListener("error", (e) => forward("error", [e.message, (e.filename || "") + ":" + e.lineno]));
  window.addEventListener("unhandledrejection", (e) => forward("error", ["unhandledrejection", String(e.reason)]));
})();
