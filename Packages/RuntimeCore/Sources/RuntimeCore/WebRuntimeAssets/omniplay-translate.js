// omniplay-translate.js — an MTool text dictionary ({"original": "translation"}) applied to RPG Maker MV/MZ text in the
// page world. The host serves the active pack's dictionary as /omniplay-translation.json (a 404 when there is none,
// and this script then does nothing). Messages and choices are matched whole, then line by line, before escape codes
// are converted; names, items and menu terms are matched where they are drawn. Hits and misses are counted for the
// session's diagnostics. With live translation on (TRANS-006), a miss is sent to the host once and shown translated
// from the next time it is drawn.
(function () {
  'use strict';
  if (window.__omniplayTranslation) return;
  var profile = __OMNIPLAY_PROFILE__;
  var dictionary = null;
  var live = {}, asked = {};
  var stats = window.__omniplayTranslation = { entries: 0, hits: 0, misses: 0 };
  try {
    var xhr = new XMLHttpRequest();
    xhr.open('GET', '/omniplay-translation.json', false);
    xhr.send();
    if (xhr.status === 200) {
      dictionary = JSON.parse(xhr.responseText);
      stats.entries = Object.keys(dictionary).length;
      console.log('[omniplay] translation dictionary: ' + stats.entries + ' entries');
    }
  } catch (e) {
    console.error('[omniplay] translation dictionary unreadable: ' + e);
  }
  if (!dictionary && !profile.liveTranslation) return;
  dictionary = dictionary || {};
  var has = Object.prototype.hasOwnProperty;
  document.addEventListener('omniplay:translated', function (e) {
    var map = e.detail || {};
    for (var k in map) if (has.call(map, k) && typeof map[k] === 'string') live[k] = map[k];
  });

  function translate(text) {
    if (typeof text !== 'string' || text === '') return text;
    if (has.call(dictionary, text)) { stats.hits++; return dictionary[text]; }
    if (text.indexOf('\n') >= 0) {
      var changed = false;
      var lines = text.split('\n').map(function (line) {
        if (has.call(dictionary, line)) { changed = true; return dictionary[line]; }
        return line;
      });
      if (changed) { stats.hits++; return lines.join('\n'); }
    }
    stats.misses++;
    if (profile.liveTranslation) {
      if (has.call(live, text)) return live[text];
      if (!asked[text] && /\S/.test(text)) {
        asked[text] = true;
        document.dispatchEvent(new CustomEvent('omniplay:missed', { detail: text }));
      }
    }
    return text;
  }
  window.__omniplayTranslate = translate;

  function install() {
    if (typeof Window_Base === 'undefined') return false;
    var convert = Window_Base.prototype.convertEscapeCharacters;
    Window_Base.prototype.convertEscapeCharacters = function (text) {
      return convert.call(this, translate(text));
    };
    var drawText = Window_Base.prototype.drawText;
    Window_Base.prototype.drawText = function (text) {
      var args = Array.prototype.slice.call(arguments);
      if (typeof text === 'string') args[0] = translate(text);
      return drawText.apply(this, args);
    };
    return true;
  }
  if (!install()) {
    var timer = setInterval(function () { if (install()) clearInterval(timer); }, 20);
  }
})();
