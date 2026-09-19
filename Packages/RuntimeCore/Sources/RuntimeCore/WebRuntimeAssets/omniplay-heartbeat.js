// Heartbeat (isolated world): the host treats 8 s of silence while running as a dead web process.
(() => {
  const beat = () => window.webkit?.messageHandlers?.["omniplay.heartbeat"]?.postMessage({ t: Date.now() });
  beat();
  setInterval(beat, 2000);
})();
