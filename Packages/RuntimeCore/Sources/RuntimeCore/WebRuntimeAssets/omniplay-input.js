// Input bridge (page world). The host batches GameInputEvents once per frame and delivers them as one DOM event
// carrying a JSON array; this turns them into real KeyboardEvent / MouseEvent dispatches and feeds a
// navigator.getGamepads() polyfill (one standard-mapping pad) so engines poll a physical controller natively.
(() => {
  const BUTTON = { a: 0, b: 1, x: 2, y: 3, leftShoulder: 4, rightShoulder: 5, leftTrigger: 6, rightTrigger: 7, options: 8, menu: 9,
    leftThumbstickButton: 10, rightThumbstickButton: 11, dpadUp: 12, dpadDown: 13, dpadLeft: 14, dpadRight: 15, home: 16 };
  const AXIS = { leftX: 0, leftY: 1, rightX: 2, rightY: 3 };
  const MOUSE_BUTTON = { primary: 0, middle: 1, secondary: 2 };
  const pad = { id: "OmniPlay Controller (STANDARD GAMEPAD)", index: 0, connected: true, mapping: "standard", timestamp: 0,
    axes: [0, 0, 0, 0], buttons: Array.from({ length: 17 }, () => ({ pressed: false, touched: false, value: 0 })) };
  let padActive = false, errorLogged = false;
  const activatePad = () => {
    if (padActive) return;
    padActive = true;
    navigator.getGamepads = () => [pad];
    try { window.dispatchEvent(new Event("gamepadconnected")); } catch (_) {}
  };
  const key = (e) => {
    const init = { key: e.key, code: e.code, keyCode: e.keyCode, which: e.keyCode, bubbles: true, cancelable: true };
    const ev = new KeyboardEvent(e.down ? "keydown" : "keyup", init);
    for (const name of ["keyCode", "which"]) { try { Object.defineProperty(ev, name, { get: () => e.keyCode }); } catch (_) {} }
    document.dispatchEvent(ev);
  };
  const mouse = (type, e) => {
    const init = { clientX: e.x, clientY: e.y, screenX: e.x, screenY: e.y, button: MOUSE_BUTTON[e.button] ?? 0,
      buttons: type === "mouseup" ? 0 : (e.button === "secondary" ? 2 : e.button === "middle" ? 4 : 1), bubbles: true, cancelable: true };
    const target = document.elementFromPoint(e.x, e.y) || document.body || document;
    try { target.dispatchEvent(new PointerEvent(type.replace("mouse", "pointer"), { ...init, pointerId: 1, pointerType: "mouse", isPrimary: true })); } catch (_) {}
    target.dispatchEvent(new MouseEvent(type, init));
  };
  const apply = (e) => {
    switch (e.t) {
      case "key": key(e); break;
      case "pointer": mouse(e.phase === "move" ? "mousemove" : e.phase === "down" ? "mousedown" : "mouseup", e); break;
      case "scroll": (document.body || document).dispatchEvent(new WheelEvent("wheel", { deltaX: e.dx, deltaY: e.dy, bubbles: true, cancelable: true })); break;
      case "pad": { activatePad(); const i = BUTTON[e.button]; if (i !== undefined) { pad.buttons[i] = { pressed: e.pressed, touched: e.pressed, value: e.pressed ? 1 : 0 }; pad.timestamp = performance.now(); } break; }
      case "axis": { activatePad(); const i = AXIS[e.axis]; if (i !== undefined) { pad.axes[i] = i === 1 || i === 3 ? -e.value : e.value; pad.timestamp = performance.now(); } break; }
      case "text": for (const ch of String(e.text)) document.dispatchEvent(new KeyboardEvent("keypress", { key: ch, charCode: ch.charCodeAt(0), bubbles: true })); break;
    }
  };
  document.addEventListener("omniplay:input", (ev) => {
    let batch;
    try { batch = JSON.parse(String(ev.detail)); } catch (_) { return; }
    if (!Array.isArray(batch)) return;
    for (const e of batch) {
      try { apply(e); } catch (err) {
        if (!errorLogged) { errorLogged = true; console.error("OmniPlay input dispatch failed: " + err); }
      }
    }
  });
})();
