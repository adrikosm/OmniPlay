// Ogg Vorbis for the page. WebKit on iOS decodes Opus, MP3, AAC, WAV and FLAC but not Vorbis in an Ogg file, which
// is how RPG Maker MV ships every sound. Vorbis bytes handed to decodeAudioData go to OmniPlay (POST
// /__omniplay/decode-audio), which answers with PCM WAV that WebKit decodes. MV reads its loop points from the
// original bytes before decoding, so loops survive. Media elements pointed at .ogg ask for the same file's decoded
// form (?omniplay=pcm); the host returns the file unchanged when it is not Vorbis.
(() => {
  // Everything a page plays reaches the speaker through one node in front of the real destination. Normally a
  // limiter: games stack music and several sound effects past full scale (more so at fast forward), and WebKit clips
  // the sum hard, which is heard as crackle. Scripted test runs get a silent gain instead.
  const muted = __OMNIPLAY_PROFILE__.muted;
  const Ctx = window.BaseAudioContext || window.AudioContext || window.webkitAudioContext;
  const real = Ctx && Object.getOwnPropertyDescriptor(Ctx.prototype, "destination");
  if (real && real.get) {
    Object.defineProperty(Ctx.prototype, "destination", { configurable: true, get() {
      const out = real.get.call(this);
      if (window.OfflineAudioContext && this instanceof OfflineAudioContext) return out;
      if (!this.__omniplayOut) {
        let node;
        if (muted) {
          node = this.createGain();
          node.gain.value = 0;
        } else {
          node = this.createDynamicsCompressor();
          node.threshold.value = -3;
          node.knee.value = 0;
          node.ratio.value = 20;
          node.attack.value = 0.003;
          node.release.value = 0.25;
        }
        node.connect(out);
        this.__omniplayOut = node;
      }
      return this.__omniplayOut;
    } });
  }
  if (muted) {
    const play = HTMLMediaElement.prototype.play;
    HTMLMediaElement.prototype.play = function (...args) { this.muted = true; return play.apply(this, args); };
    // After load: at document start the isolated world's console capture may not be listening yet.
    window.addEventListener("load", () => console.info("OmniPlay: sound muted for this run (--mute-audio)"));
  }
  const ENDPOINT = "/__omniplay/decode-audio";
  const isOggVorbis = (buffer) => {
    if (!(buffer instanceof ArrayBuffer) || buffer.byteLength < 35) return false;
    const b = new Uint8Array(buffer, 0, 35);
    return b[0] === 0x4f && b[1] === 0x67 && b[2] === 0x67 && b[3] === 0x53 && b[28] === 0x01 &&
      String.fromCharCode(b[29], b[30], b[31], b[32], b[33], b[34]) === "vorbis";
  };

  const Base = window.BaseAudioContext || window.AudioContext || window.webkitAudioContext;
  const targets = [Base, window.webkitAudioContext, window.webkitOfflineAudioContext].filter((c) => c && c.prototype && c.prototype.decodeAudioData);
  for (const Ctx of new Set(targets)) {
    const original = Ctx.prototype.decodeAudioData;
    if (original.__omniplay) continue;
    const patched = function (buffer, success, failure) {
      if (!isOggVorbis(buffer)) return original.call(this, buffer, success, failure);
      const context = this;
      const promise = fetch(ENDPOINT, { method: "POST", body: buffer, headers: { "Content-Type": "application/ogg" } })
        .then((response) => { if (!response.ok) throw new DOMException("OmniPlay could not decode this audio", "EncodingError"); return response.arrayBuffer(); })
        .then((wav) => new Promise((resolve, reject) => original.call(context, wav, resolve, reject)));
      if (success || failure) promise.then(success, failure);
      return promise;
    };
    patched.__omniplay = true;
    Ctx.prototype.decodeAudioData = patched;
  }

  const rewrite = (value) => {
    try {
      const url = new URL(String(value), location.href);
      if (url.origin !== location.origin || !/\.ogg$/i.test(url.pathname) || url.searchParams.has("omniplay")) return value;
      url.searchParams.set("omniplay", "pcm");
      return url.href;
    } catch (_) { return value; }
  };
  // WebKit's Now Playing bookkeeping walks every live media element on each play, pause and end, and for each one
  // walks them all again. Twine games keep a preloaded <audio> per sound and clone one per play, so a long session
  // holds hundreds: the page then burns a whole core and a tap waits seconds. A detached <audio> that has ended, or
  // never started, moves after IDLE_MS into a document with no page, where WebKit forgets it; play() or cloneNode()
  // brings it back first (a clone made there could never play).
  const IDLE_MS = 3000;
  const inert = document.implementation.createHTMLDocument("");
  const tracked = new Set(), known = new WeakSet(), seen = new WeakMap();
  const track = (el) => {
    if (!(el instanceof HTMLAudioElement) || known.has(el)) return;
    known.add(el);
    seen.set(el, Date.now());
    tracked.add(new WeakRef(el));
  };
  const unpark = (el) => {
    seen.set(el, Date.now());
    if (el.ownerDocument === inert) document.adoptNode(el);
  };
  setInterval(() => {
    const now = Date.now();
    for (const ref of tracked) {
      const el = ref.deref();
      if (!el) { tracked.delete(ref); continue; }
      if (el.ownerDocument === inert) continue;
      if (!el.paused || el.networkState === HTMLMediaElement.NETWORK_LOADING) { seen.set(el, now); continue; }
      if (now - seen.get(el) >= IDLE_MS && (el.ended || el.currentTime === 0) && !el.isConnected) inert.adoptNode(el);
    }
  }, 2000);
  const media = window.HTMLMediaElement && HTMLMediaElement.prototype;
  const src = media && Object.getOwnPropertyDescriptor(media, "src");
  if (src && src.set) {
    Object.defineProperty(media, "src", { configurable: true, enumerable: src.enumerable, get: src.get,
      set(value) { track(this); unpark(this); src.set.call(this, rewrite(value)); } });
  }
  const setAttribute = Element.prototype.setAttribute;
  Element.prototype.setAttribute = function (name, value) {
    if (this instanceof HTMLMediaElement && String(name).toLowerCase() === "src") {
      value = rewrite(value);
      track(this);
      unpark(this);
    }
    return setAttribute.call(this, name, value);
  };
  if (media) {
    const play = media.play, clone = media.cloneNode;
    media.play = function (...args) { track(this); unpark(this); return play.apply(this, args); };
    media.cloneNode = function (...args) { unpark(this); return clone.apply(this, args); };
  }
  const NativeAudio = window.Audio;
  if (NativeAudio) {
    const Audio = function (...args) { const el = new NativeAudio(...args); track(el); return el; };
    Audio.prototype = NativeAudio.prototype;
    window.Audio = Audio;
  }
})();
