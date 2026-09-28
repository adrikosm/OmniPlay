// Ogg Vorbis for the page. WebKit on iOS decodes Opus, MP3, AAC, WAV and FLAC but not Vorbis in an Ogg file, which
// is how RPG Maker MV ships every sound. Vorbis bytes handed to decodeAudioData go to OmniPlay (POST
// /__omniplay/decode-audio), which answers with PCM WAV that WebKit decodes. MV reads its loop points from the
// original bytes before decoding, so loops survive. Media elements pointed at .ogg ask for the same file's decoded
// form (?omniplay=pcm); the host returns the file unchanged when it is not Vorbis.
(() => {
  // Scripted test runs: Web Audio goes through a silent gain and every media element plays muted.
  if (__OMNIPLAY_PROFILE__.muted) {
    const Ctx = window.BaseAudioContext || window.AudioContext || window.webkitAudioContext;
    const real = Ctx && Object.getOwnPropertyDescriptor(Ctx.prototype, "destination");
    if (real && real.get) {
      Object.defineProperty(Ctx.prototype, "destination", { configurable: true, get() {
        if (!this.__omniplaySilent) {
          this.__omniplaySilent = this.createGain();
          this.__omniplaySilent.gain.value = 0;
          this.__omniplaySilent.connect(real.get.call(this));
        }
        return this.__omniplaySilent;
      } });
    }
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
  const media = window.HTMLMediaElement && HTMLMediaElement.prototype;
  const src = media && Object.getOwnPropertyDescriptor(media, "src");
  if (src && src.set) {
    Object.defineProperty(media, "src", { configurable: true, enumerable: src.enumerable, get: src.get, set(value) { src.set.call(this, rewrite(value)); } });
  }
  const setAttribute = Element.prototype.setAttribute;
  Element.prototype.setAttribute = function (name, value) {
    if (this instanceof HTMLMediaElement && String(name).toLowerCase() === "src") value = rewrite(value);
    return setAttribute.call(this, name, value);
  };
})();
