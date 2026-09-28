#!/usr/bin/env python3
"""Builds one probe game per engine around the media corpus (make-media-corpus.py): import the probe into OmniPlay,
play it, and it reports which files the engine decoded.

  probe-web     HTML5 game for WebKit. Each result is a console line starting OMNIPROBE, which OmniPlay keeps in the
                session's web-console.log; the page also shows every image and video it decoded.
  probe-rgss    RPG Maker VX Ace game for mkxp-z. Loads every image as a Bitmap (with and without its extension,
                as RGSS games name files), plays every sound as BGM and every video with Graphics.play_movie, and
                writes one line per file to Save99.rvdata2 in the game's save folder.
  probe-renpy   Ren'Py 8.5.3 game. Loads every image through Ren'Py's image loader, plays every sound and checks the
                music position, shows every video as a Movie and checks its channel; lines start OMNIPROBE in the
                session's python.log.

Output is local only (Fixtures/private). Usage: make-media-probes.py [--corpus DIR] [--out DIR]
"""

import argparse
import json
import os
import shutil
import zlib

WEB_PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>OmniPlay media probe</title>
<style>
 body { background:#111; color:#ddd; font:10px -apple-system, sans-serif; margin:4px; }
 .grid { display:flex; flex-wrap:wrap; gap:4px; }
 .cell { width:112px; } .cell img, .cell video, .cell canvas { width:112px; height:63px; object-fit:contain; background:#333; display:block; }
 .ok { color:#6d6; } .bad { color:#e55; } #status { font-size:14px; margin:4px 0; }
</style></head>
<body><div id="status">probing…</div><div class="grid" id="grid"></div>
<script src="probe.js"></script></body></html>
"""

WEB_PROBE = r"""
// OmniPlay media probe: decodes every file in media/ the way games do and reports one OMNIPROBE line per file.
const MANIFEST = __MANIFEST__;
const MIME = { mp4: "video/mp4", m4v: "video/mp4", mov: "video/quicktime", mkv: "video/x-matroska", webm: "video/webm",
  ogv: "video/ogg", avi: "video/x-msvideo", mpg: "video/mpeg", ts: "video/mp2t", wmv: "video/x-ms-wmv",
  ogg: "audio/ogg", opus: "audio/ogg; codecs=opus", mka: "audio/x-matroska", mp3: "audio/mpeg", m4a: "audio/mp4", wav: "audio/wav", flac: "audio/flac",
  aiff: "audio/aiff", wma: "audio/x-ms-wma", ac3: "audio/ac3", mid: "audio/midi" };
const report = (o) => console.log("OMNIPROBE " + JSON.stringify(o));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const ext = (f) => f.split(".").pop().toLowerCase();
const grid = document.getElementById("grid");
const cell = (label, el, ok) => {
  const d = document.createElement("div"); d.className = "cell";
  if (el) d.appendChild(el);
  const t = document.createElement("div"); t.textContent = (ok ? "✓ " : "✗ ") + label; t.className = ok ? "ok" : "bad";
  d.appendChild(t); grid.appendChild(d);
};
const race = (target, events, ms) => new Promise((resolve) => {
  const done = (name) => { events.forEach((e) => target.removeEventListener(e, handlers[e])); clearTimeout(timer); resolve(name); };
  const handlers = {}; events.forEach((e) => { handlers[e] = () => done(e); target.addEventListener(e, handlers[e]); });
  const timer = setTimeout(() => done("timeout"), ms);
});
const litPixels = (source, w, h) => {
  const c = document.createElement("canvas"); c.width = 32; c.height = 18;
  const g = c.getContext("2d"); g.drawImage(source, 0, 0, 32, 18);
  const d = g.getImageData(0, 0, 32, 18).data; let lit = 0;
  for (let i = 0; i < d.length; i += 4) if (d[i] + d[i + 1] + d[i + 2] > 30) lit++;
  return lit;
};

// Coarse picture signature, to tell whether an animated image or a canvas has moved on to another frame.
const signature = (source) => {
  const c = document.createElement("canvas"); c.width = 16; c.height = 16;
  const g = c.getContext("2d"); g.drawImage(source, 0, 0, 16, 16);
  const d = g.getImageData(0, 0, 16, 16).data; let h = 0;
  for (let i = 0; i < d.length; i++) h = (h * 31 + d[i]) >>> 0;
  return h;
};
// Upload as a WebGL texture and read the centre pixel back, the way PIXI-based engines (RPG Maker MV/MZ) draw images.
let glCanvas, gl;
const glUpload = (source) => {
  try {
    glCanvas = glCanvas || document.createElement("canvas");
    gl = gl || glCanvas.getContext("webgl2") || glCanvas.getContext("webgl");
    if (!gl) return "no webgl";
    const tex = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, source);
    const err = gl.getError(); if (err) { gl.deleteTexture(tex); return "error " + err; }
    const fb = gl.createFramebuffer(); gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
    const w = source.videoWidth || source.naturalWidth || source.width, h = source.videoHeight || source.naturalHeight || source.height;
    const px = new Uint8Array(4); gl.readPixels(w >> 1, h >> 1, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
    gl.bindFramebuffer(gl.FRAMEBUFFER, null); gl.deleteFramebuffer(fb); gl.deleteTexture(tex);
    return "ok " + Array.from(px).join(",");
  } catch (e) { return "error " + (e.name || e); }
};

async function probeVideo(file) {
  const v = document.createElement("video");
  v.muted = true; v.playsInline = true; v.preload = "auto"; v.src = "media/video/" + file;
  const r = { kind: "video", file, canPlayType: v.canPlayType(MIME[ext(file)] || "") };
  // iOS WebKit loads no media data before playback starts, so play first and wait for frames.
  const started = race(v, ["playing", "error"], 8000);
  v.play().then(() => { r.play = "ok"; }, (e) => { r.play = String(e.name || e); });
  r.load = await started;
  r.error = v.error ? v.error.code : null;
  if (r.load === "playing") {
    r.size = v.videoWidth + "x" + v.videoHeight;
    await sleep(1500);
    r.time = Math.round(v.currentTime * 100) / 100;
    try { r.lit = litPixels(v); } catch (e) { r.lit = "error " + e; }
    r.audioTracks = v.audioTracks ? v.audioTracks.length : null;
    r.texture = glUpload(v);
    v.pause();
    // Games restart and skip cutscenes by seeking.
    v.currentTime = 0.2;
    r.seek = await race(v, ["seeked", "error"], 3000);
  }
  r.ok = r.load === "playing" && r.time > 0.5 && r.lit > 0 && r.seek === "seeked" && String(r.texture).startsWith("ok");
  cell(file, r.ok ? v : null, r.ok);
  if (!r.ok) { v.removeAttribute("src"); v.load(); }
  report(r);
}

let audioContext;
async function probeAudio(file) {
  const r = { kind: "audio", file };
  const a = new Audio(); a.src = "media/audio/" + file;
  r.canPlayType = a.canPlayType(MIME[ext(file)] || "");
  a.volume = 0.05;
  const started = race(a, ["playing", "error"], 6000);
  a.play().catch((e) => { r.elementPlay = String(e.name || e); });
  r.element = await started;
  if (r.element === "playing") { await sleep(800); r.elementTime = Math.round(a.currentTime * 100) / 100; }
  a.pause();
  // RPG Maker MV decodes every sound with WebAudio (fetch, then decodeAudioData).
  try {
    audioContext = audioContext || new (window.AudioContext || window.webkitAudioContext)();
    const buffer = await (await fetch("media/audio/" + file)).arrayBuffer();
    const decoded = await new Promise((resolve, reject) => audioContext.decodeAudioData(buffer, resolve, reject));
    r.webAudio = "ok " + decoded.duration.toFixed(2) + "s " + decoded.numberOfChannels + "ch";
  } catch (e) { r.webAudio = "error " + (e && (e.name || e.message) || e); }
  r.ok = (r.elementTime > 0.3) || r.webAudio.startsWith("ok");
  cell(file + (r.webAudio.startsWith("ok") ? "" : " (no WebAudio)"), null, r.ok);
  report(r);
}

async function probeImage(file) {
  const r = { kind: "image", file };
  const img = new Image(); img.src = "media/image/" + file;
  try { await img.decode(); r.img = img.naturalWidth + "x" + img.naturalHeight; r.lit = litPixels(img); } catch (e) { r.img = "error " + (e.name || e); }
  if (!String(r.img).startsWith("error")) {
    r.texture = glUpload(img);
    // Frames seen when the animated image is drawn into a canvas, sampled four times over a second. WebKit draws the
    // first frame there (on the page the image does animate: compare two screenshots), so this is recorded, not judged.
    if (file.includes("animated")) {
      const holder = document.createElement("div"); holder.style.cssText = "position:fixed;right:0;bottom:0;width:64px;height:64px";
      const live = img.cloneNode(); live.style.width = "64px"; holder.appendChild(live); document.body.appendChild(holder);
      try { await live.decode(); } catch (_) {}
      const seen = new Set();
      for (let i = 0; i < 4; i++) { seen.add(signature(live)); await sleep(300); }
      r.canvasFrames = seen.size;
      holder.remove();
    }
  }
  try {
    const bmp = await createImageBitmap(await (await fetch("media/image/" + file)).blob());
    r.bitmap = bmp.width + "x" + bmp.height; bmp.close();
  } catch (e) { r.bitmap = "error " + (e.name || e); }
  r.ok = !String(r.img).startsWith("error") && r.lit > 0 && String(r.texture).startsWith("ok");
  cell(file + (r.canvasFrames === 1 ? " (canvas: first frame)" : ""), r.ok ? img : null, r.ok);
  report(r);
}

async function probeEnvironment() {
  const env = { kind: "env", userAgent: navigator.userAgent };
  const gl2 = document.createElement("canvas").getContext("webgl2");
  const gl = gl2 || document.createElement("canvas").getContext("webgl");
  env.webgl = gl2 ? "webgl2" : gl ? "webgl1" : "none";
  if (gl) { const d = gl.getExtension("WEBGL_debug_renderer_info"); env.renderer = d ? gl.getParameter(d.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER); env.maxTexture = gl.getParameter(gl.MAX_TEXTURE_SIZE); }
  try { const m = await WebAssembly.instantiateStreaming(fetch("probe.wasm")); env.wasmStreaming = "ok " + typeof m.instance.exports.add; } catch (e) { env.wasmStreaming = "error " + e; }
  try { const b = await (await fetch("probe.wasm")).arrayBuffer(); const m = await WebAssembly.instantiate(b); env.wasm = "ok " + m.instance.exports.add(2, 3); } catch (e) { env.wasm = "error " + e; }
  env.mediaSource = typeof MediaSource !== "undefined" ? { webmVP9: MediaSource.isTypeSupported('video/webm; codecs="vp9"'), webmVP8: MediaSource.isTypeSupported('video/webm; codecs="vp8"'), mp4H264: MediaSource.isTypeSupported('video/mp4; codecs="avc1.64001f"') } : "none";
  const v = document.createElement("video"); const a = document.createElement("audio");
  env.canPlayType = {};
  for (const t of ['video/webm; codecs="vp8, vorbis"', 'video/webm; codecs="vp9, opus"', 'video/webm; codecs="av01.0.05M.08"', 'video/mp4; codecs="avc1.64001f, mp4a.40.2"', 'video/mp4; codecs="hvc1.1.6.L93.B0"', 'video/mp4; codecs="av01.0.05M.08"', 'video/ogg; codecs="theora, vorbis"'])
    env.canPlayType[t] = v.canPlayType(t);
  for (const t of ['audio/ogg; codecs="vorbis"', 'audio/ogg; codecs="opus"', "audio/mpeg", 'audio/mp4; codecs="mp4a.40.2"', "audio/wav", "audio/flac"])
    env.canPlayType[t] = a.canPlayType(t);
  report(env);
}

// Page animations the way HTML games use them. Each passes on a measured change, never on a screenshot.
async function probeAnimations() {
  const box = () => { const d = document.createElement("div"); d.style.cssText = "position:absolute;left:0;top:0;width:20px;height:20px;background:#f2b233"; document.body.appendChild(d); return d; };
  const result = (name, ok, detail) => { report({ kind: "animation", name, ok, detail }); cell(name + " " + detail, null, ok); };
  // requestAnimationFrame: frames in one second.
  let frames = 0; const t0 = performance.now();
  await new Promise((resolve) => { const tick = () => { frames++; performance.now() - t0 < 1000 ? requestAnimationFrame(tick) : resolve(); }; requestAnimationFrame(tick); });
  result("requestAnimationFrame", frames >= 30, frames + " fps");
  // CSS keyframes: the computed transform changes while it runs.
  const style = document.createElement("style");
  style.textContent = "@keyframes op-move{from{transform:translateX(0)}to{transform:translateX(200px)}} .op-kf{animation:op-move 1s linear infinite}";
  document.head.appendChild(style);
  const kf = box(); kf.className = "op-kf"; await sleep(150);
  const a = getComputedStyle(kf).transform; await sleep(300); const b = getComputedStyle(kf).transform;
  result("css-keyframes", a !== b && a !== "none", a + " → " + b); kf.remove();
  // CSS transition: transitionend arrives.
  const tr = box(); tr.style.transition = "left 0.3s linear"; await sleep(50); tr.style.left = "100px";
  const ended = await race(tr, ["transitionend"], 2000); result("css-transition", ended === "transitionend", ended); tr.remove();
  // Web Animations API.
  const wa = box(); let finished = "timeout";
  try { const an = wa.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 300 }); finished = await Promise.race([an.finished.then(() => "finished"), sleep(2000).then(() => "timeout")]); } catch (e) { finished = "error " + e; }
  result("web-animations", finished === "finished", finished); wa.remove();
  // Canvas drawn every frame (how canvas games animate).
  const c = document.createElement("canvas"); c.width = 64; c.height = 64; document.body.appendChild(c);
  const g = c.getContext("2d"); let x = 0, run = true;
  const draw = () => { g.fillStyle = "#111"; g.fillRect(0, 0, 64, 64); g.fillStyle = "#3b6fd8"; g.fillRect(x = (x + 2) % 64, 20, 16, 16); if (run) requestAnimationFrame(draw); };
  draw(); await sleep(100); const s1 = signature(c); await sleep(300); const s2 = signature(c); run = false;
  result("canvas-raf", s1 !== s2, s1 + " → " + s2); c.remove();
  // SVG SMIL: an animated attribute's live value moves.
  const holder = document.createElement("div");
  holder.innerHTML = '<svg width="64" height="64"><circle cx="8" cy="32" r="8" fill="#d93030"><animate attributeName="cx" values="8;56;8" dur="1s" repeatCount="indefinite"/></circle></svg>';
  document.body.appendChild(holder); const circle = holder.querySelector("circle"); await sleep(150);
  const c1 = circle.cx.animVal.value; await sleep(300); const c2 = circle.cx.animVal.value;
  result("svg-smil", c1 !== c2, c1.toFixed(1) + " → " + c2.toFixed(1)); holder.remove();
}

(async () => {
  const status = document.getElementById("status");
  report({ kind: "start", files: MANIFEST.video.length + MANIFEST.audio.length + MANIFEST.image.length });
  await probeEnvironment();
  status.textContent = "animations"; await probeAnimations();
  for (const f of MANIFEST.image) { status.textContent = "image " + f; await probeImage(f); }
  for (const f of MANIFEST.audio) { status.textContent = "audio " + f; await probeAudio(f); }
  for (const f of MANIFEST.video) { status.textContent = "video " + f; await probeVideo(f); }
  status.textContent = "done";
  report({ kind: "done" });
})();
"""

# (module (func (export "add") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add))
WASM_ADD = bytes.fromhex("0061736d0100000001070160027f7f017f030201000707010361646400000a09010700200020016a0b")


def web(corpus, out):
    shutil.rmtree(out, ignore_errors=True)
    shutil.copytree(corpus, os.path.join(out, "media"))
    manifest = json.load(open(os.path.join(corpus, "manifest.json")))
    open(os.path.join(out, "index.html"), "w").write(WEB_PAGE)
    open(os.path.join(out, "probe.js"), "w").write(WEB_PROBE.replace("__MANIFEST__", json.dumps(manifest)))
    open(os.path.join(out, "probe.wasm"), "wb").write(WASM_ADD)


RGSS_PROBE = """# OmniPlay media probe (RGSS3). One line per file, written as Save99.rvdata2: mkxp-z sends only save-shaped names
# to the save folder, and the game folder itself is read-only.
$lines = []
def report(line)
  $lines << line
  File.open("Save99.rvdata2", "wb") { |f| f.write($lines.join("\\n") + "\\n") }
end
screen = Sprite.new
screen.bitmap = Bitmap.new(Graphics.width, Graphics.height)
status = Sprite.new
status.bitmap = Bitmap.new(Graphics.width, 24)
status.y = Graphics.height - 24
show = lambda { |text| status.bitmap.clear; status.bitmap.draw_text(0, 0, Graphics.width, 24, text, 1); Graphics.update }
IMAGES = __IMAGES__
AUDIO = __AUDIO__
MOVIES = __MOVIES__
report("start ruby " + RUBY_VERSION)
IMAGES.each_with_index do |name, i|
  show.call(name)
  [name, name.sub(/\\.[^.]+$/, "")].uniq.each do |ref|
    begin
      b = Bitmap.new("Graphics/Pictures/" + ref)
      c = b.get_pixel(b.width / 2, b.height / 2)
      report("image " + ref + " ok " + b.width.to_s + "x" + b.height.to_s + " rgba " + [c.red, c.green, c.blue, c.alpha].map { |v| v.to_i }.join(","))
      if ref == name
        x = (i % 10) * 54
        y = (i / 10) * 54
        screen.bitmap.stretch_blt(Rect.new(x, y, 52, 52), b, b.rect)
      end
      b.dispose
    rescue Exception => e
      report("image " + ref + " error " + e.class.to_s + ": " + e.message.to_s[0, 120])
    end
  end
end
AUDIO.each do |name|
  show.call(name)
  begin
    Audio.bgm_play("Audio/BGM/" + name, 40)
    45.times { Graphics.update }
    pos = Audio.respond_to?(:bgm_pos) ? Audio.bgm_pos : -1
    report("audio " + name + " ok pos " + pos.to_s)
    Audio.bgm_stop
  rescue Exception => e
    report("audio " + name + " error " + e.class.to_s + ": " + e.message.to_s[0, 120])
  end
end
MOVIES.each do |name|
  show.call(name)
  started = Time.now
  begin
    Graphics.play_movie("Movies/" + name)
    report("movie " + name + " returned after " + ((Time.now - started) * 100).round.to_s + "cs")
  rescue Exception => e
    report("movie " + name + " error " + e.class.to_s + ": " + e.message.to_s[0, 120])
  end
end
report("done")
show.call("done")
loop { Graphics.update }
"""


def marshal_long(n):
    if n == 0:
        return b"\x00"
    if 0 < n < 123:
        return bytes([n + 5])
    body = n.to_bytes(4, "little").rstrip(b"\x00")
    return bytes([len(body)]) + body


def rgss_script_pack(entries):
    """Marshal 4.8 array of [id, name, zlib(source)], the script archive RPG Maker writes."""
    out = b"\x04\x08[" + marshal_long(len(entries))
    for index, (name, source) in enumerate(entries):
        body = zlib.compress(source.encode("utf-8"), 9)
        out += b"[" + marshal_long(3) + b"i" + marshal_long(index + 1)
        out += b'"' + marshal_long(len(name)) + name.encode("utf-8") + b'"' + marshal_long(len(body)) + body
    return out


def rgss(corpus, out):
    shutil.rmtree(out, ignore_errors=True)
    manifest = json.load(open(os.path.join(corpus, "manifest.json")))
    for kind, folder in [("image", "Graphics/Pictures"), ("audio", "Audio/BGM"), ("video", "Movies")]:
        shutil.copytree(os.path.join(corpus, kind), os.path.join(out, folder))
    ruby_list = lambda names: "[" + ", ".join('"%s"' % n for n in names) + "]"
    script = RGSS_PROBE.replace("__IMAGES__", ruby_list(manifest["image"])).replace("__AUDIO__", ruby_list(manifest["audio"]))
    script = script.replace("__MOVIES__", ruby_list(manifest["video"]))
    os.makedirs(os.path.join(out, "Data"))
    open(os.path.join(out, "Data", "Scripts.rvdata2"), "wb").write(rgss_script_pack([("Probe", script)]))
    open(os.path.join(out, "Game.ini"), "w").write(
        "[Game]\r\nRTP=\r\nLibrary=System\\RGSS301.dll\r\nScripts=Data\\Scripts.rvdata2\r\nTitle=OmniPlay Media Probe\r\n")
    open(os.path.join(out, "Game.exe"), "wb").write(b"MZ" + bytes(126))


RENPY_PROBE = """# OmniPlay media probe (Ren'Py). One OMNIPROBE line per file on stdout (the session's python.log).
define config.name = "OmniPlay RenPy Probe"

label main_menu:
    return

init python:
    PROBE_IMAGES = __IMAGES__
    PROBE_AUDIO = __AUDIO__
    PROBE_MOVIES = __MOVIES__

    def probe_report(kind, name, result):
        import sys
        sys.stdout.write("OMNIPROBE %s %s %s\\n" % (kind, name, result))

label start:
    python:
        probe_report("start", "renpy", renpy.version())
        # SVG renders through the display, which exists from the first interaction on.
        renpy.pause(0.5, hard=True)
        for f in PROBE_IMAGES:
            try:
                surface = renpy.display.im.Image("images/probe/" + f).load()
                probe_report("image", f, "ok %dx%d" % surface.get_size())
            except Exception as e:
                probe_report("image", f, "error %s: %s" % (type(e).__name__, str(e)[:120]))
        for f in PROBE_AUDIO:
            try:
                renpy.music.play("audio/probe/" + f, channel="music", loop=False)
                renpy.pause(1.0, hard=True)
                pos = renpy.music.get_pos(channel="music")
                probe_report("audio", f, "ok pos %s" % (pos,) if pos else "silent")
            except Exception as e:
                probe_report("audio", f, "error %s: %s" % (type(e).__name__, str(e)[:120]))
            renpy.music.stop(channel="music")
        for f in PROBE_MOVIES:
            try:
                renpy.show("probe_movie", what=Movie(play="movies/probe/" + f, size=(640, 360), loop=False))
                renpy.pause(2.0, hard=True)
                # Ren'Py 8 gives each Movie a channel of its own (_movie_1...); 7.x uses movie_dp.
                channel = (list(renpy.display.video.channel_movie) or ["movie_dp"])[0]
                pos = renpy.music.get_pos(channel=channel)
                # The newest decoded frame the Movie displayable drew; None when no picture came out.
                frame = renpy.display.video.texture.get(channel)
                picture = "frame %dx%d" % frame.get_size() if frame is not None else "no frame"
                probe_report("movie", f, ("ok pos %s " % (pos,) if pos else "silent ") + picture)
            except Exception as e:
                probe_report("movie", f, "error %s: %s" % (type(e).__name__, str(e)[:120]))
            renpy.hide("probe_movie")
            renpy.music.stop(channel="movie_dp")
        probe_report("done", "renpy", "")
    "Probe done."
    return
"""


def renpy_probe(corpus, out, version_file):
    shutil.rmtree(out, ignore_errors=True)
    manifest = json.load(open(os.path.join(corpus, "manifest.json")))
    for kind, folder in [("image", "game/images/probe"), ("audio", "game/audio/probe"), ("video", "game/movies/probe")]:
        shutil.copytree(os.path.join(corpus, kind), os.path.join(out, folder))
    py_list = lambda names: "[" + ", ".join('"%s"' % n for n in names) + "]"
    script = RENPY_PROBE.replace("__IMAGES__", py_list(manifest["image"])).replace("__AUDIO__", py_list(manifest["audio"]))
    script = script.replace("__MOVIES__", py_list(manifest["video"]))
    open(os.path.join(out, "game", "script.rpy"), "w").write(script)
    os.makedirs(os.path.join(out, "renpy"))
    shutil.copy(version_file, os.path.join(out, "renpy", "vc_version.py"))


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", default=os.path.join(root, "Fixtures/private/media-corpus"))
    parser.add_argument("--out", default=os.path.join(root, "Fixtures/private"))
    args = parser.parse_args()
    web(args.corpus, os.path.join(args.out, "probe-web"))
    rgss(args.corpus, os.path.join(args.out, "probe-rgss"))
    # One probe per bundled engine: the version file decides which one OmniPlay runs it on.
    for folder, version in [("probe-renpy", "8.5.3"), ("probe-renpy83", "8.3.7"), ("probe-renpy78", "7.8.7")]:
        version_file = os.path.join(root, "Native/build/renpy/%s/renpy-%s-sdk/renpy/vc_version.py" % (version, version))
        if os.path.exists(version_file):
            renpy_probe(args.corpus, os.path.join(args.out, folder), version_file)
    print("wrote the probes to", args.out)


if __name__ == "__main__":
    main()
