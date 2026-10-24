// omniplay-web-state.js — typed state for HTML games other than RPG Maker, in the page world, under
// window.__omniplayWebState. The protocol is omniplay-state.js's ({op: list|get|set|freeze|unfreeze|metadata}); every
// target is {kind: "path", root, path}. One adapter per engine, the first that finds its globals:
//   SugarCube 2  $ (State.variables), _ (State.temporary); UIBar.update() after a write
//   Harlowe 3    $ (the story's variables); a change shows on the next passage
//   TyranoScript f (game), sf (system: kept on disk, saved after a write), tf (temporary)
//   any page     window: what the game's own scripts added to window, two levels deep
// Nothing here runs by itself, apart from taking the window baseline and handing Harlowe's state over.
(function () {
  'use strict';
  if (window.__omniplayWebState) return;

  // Window properties that exist before any game script runs; the plain-page adapter lists only what came after.
  var baseline = Object.create(null);
  Object.keys(window).forEach(function (k) { baseline[k] = true; });

  // Harlowe 3.3.8 and 3.3.9 keep State inside their module closure and ship no Harlowe.API_ACCESS. Story scripts are
  // evaluated where `State` is in scope, so one more story script, added as the story data is parsed (before the
  // engine's own script runs), hands it over. It is only text of an unknown script type: the browser never runs it.
  var watch = new MutationObserver(function (records) {
    records.forEach(function (r) {
      r.addedNodes.forEach(function (node) {
        if (node.nodeName !== 'TW-STORYDATA' || !/^harlowe$/i.test(node.getAttribute('format') || '')) return;
        var s = document.createElement('script');
        s.setAttribute('role', 'script');
        s.type = 'text/twine-javascript';
        s.textContent = 'window.__omniplayHarloweState = State;';
        node.appendChild(s);
      });
    });
  });
  watch.observe(document, { childList: true, subtree: true });
  document.addEventListener('DOMContentLoaded', function () { watch.disconnect(); }, { once: true });

  function own(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }
  function isLeaf(v) {
    return typeof v === 'boolean' || typeof v === 'string' || (typeof v === 'number' && isFinite(v));
  }

  // The engine in this page, or the plain page. Each probe is guarded: a missing global falls through to the next.
  function adapter() {
    var sc = window.SugarCube;
    if (sc && sc.State && sc.State.variables) {
      return {
        name: 'SugarCube',
        roots: { '$': function () { return sc.State.variables; }, '_': function () { return sc.State.temporary; } },
        after: function () { if (sc.UIBar && typeof sc.UIBar.update === 'function') sc.UIBar.update(); }
      };
    }
    var api = window.Harlowe && window.Harlowe.API_ACCESS;
    var hs = (api && api.STATE) || window.__omniplayHarloweState;
    if (hs && hs.variables) {
      return {
        name: 'Harlowe',
        roots: { '$': function () { return hs.variables; } },
        hidden: function (k) { return k.indexOf('TwineScript_') === 0; },
        note: 'Shows on the next passage.',
        // Through TwineScript_Set, as (set:) does, so the change is part of the turn and of the next save.
        set: function (root, path, value) {
          if (path.length !== 1) throw new Error('In Harlowe only whole variables can be changed, not parts of them.');
          var vars = hs.variables;
          if (typeof vars.TwineScript_Set === 'function') vars.TwineScript_Set(path[0], value); else vars[path[0]] = value;
        }
      };
    }
    var kag = window.TYRANO && window.TYRANO.kag;
    if (kag && kag.stat && kag.variable) {
      return {
        name: 'TyranoScript',
        roots: {
          f: function () { return kag.stat.f; },
          sf: function () { return kag.variable.sf; },
          tf: function () { return kag.variable.tf; }
        },
        persistent: { sf: true },
        after: function (root) { if (root === 'sf' && typeof kag.saveSystemVariable === 'function') kag.saveSystemVariable(); }
      };
    }
    return {
      name: 'page',
      roots: { window: function () { return window; } },
      hidden: function (k, v) {
        return baseline[k] || /^(__omniplay|OmniPlay$|webkit)/.test(k) || typeof v === 'function' ||
          (typeof Node !== 'undefined' && v instanceof Node) || v === window;
      }
    };
  }

  // JSON for the host: leaves as they are, lists, maps (Harlowe datamaps), sets and objects `depth` levels deep, at most
  // 100 keys a level. Functions, DOM nodes and what lies deeper are left out.
  var SKIP = {};
  function wire(v, depth) {
    if (v === null || v === undefined) return null;
    if (isLeaf(v)) return v;
    if (typeof v === 'number') return String(v); // NaN, Infinity
    if (typeof v !== 'object' || (typeof Node !== 'undefined' && v instanceof Node) || v === window || depth <= 0) return SKIP;
    var out, n = 0;
    function put(k, x) {
      if (n >= 100) return;
      var w = wire(x, depth - 1);
      if (w !== SKIP) { out[String(k)] = w; n++; }
    }
    if (Array.isArray(v) || v instanceof Set) {
      out = [];
      Array.from(v).slice(0, 100).forEach(function (x) { var w = wire(x, depth - 1); out.push(w === SKIP ? null : w); });
      return out;
    }
    out = {};
    if (v instanceof Map) v.forEach(function (x, k) { put(k, x); });
    else Object.keys(v).forEach(function (k) { try { put(k, v[k]); } catch (e) { /* a throwing getter */ } });
    return out;
  }

  function step(container, key) {
    if (container === null || container === undefined) throw new Error('nothing at ' + key);
    if (container instanceof Map) return container.get(key);
    if (Array.isArray(container)) return container[Number(key)];
    return container[key];
  }
  function rootOf(a, t) {
    var get = t && a.roots[t.root];
    if (!get) throw new Error('no ' + (t && t.root) + ' in this ' + a.name + ' game');
    return get();
  }
  function read(a, t) {
    var v = rootOf(a, t);
    (t.path || []).forEach(function (k) { v = step(v, k); });
    return v;
  }

  function entry(a, t, name, v, w) {
    return { target: t, name: name, value: w === SKIP ? null : w, editable: isLeaf(v),
      persistent: !!(a.persistent && a.persistent[t.root]) };
  }
  function label(root, key) {
    return root === '$' || root === '_' ? root + key : root === 'window' ? key : root + '.' + key;
  }
  function entries(a, category, query) {
    if (category !== 'store') throw new Error('category not available here: ' + category);
    var out = [], q = (query || '').toLowerCase();
    Object.keys(a.roots).forEach(function (root) {
      var r = a.roots[root]();
      if (!r) return;
      Object.keys(r).sort().forEach(function (k) {
        var v;
        try { v = r[k]; } catch (e) { return; }
        if ((a.hidden && a.hidden(k, v)) || typeof v === 'function') return;
        var name = label(root, k);
        if (q && name.toLowerCase().indexOf(q) < 0) return;
        var w = wire(v, 2);
        if (w !== SKIP) out.push(entry(a, { kind: 'path', root: root, path: [k] }, name, v, w));
      });
    });
    return out;
  }

  // The new value in the old one's type: a number stays a number, a flag a flag, text text.
  function coerce(old, value) {
    if (typeof old === 'boolean') return !!value;
    if (typeof old === 'number') {
      var n = Number(value);
      if (!isFinite(n)) throw new Error('expected a number');
      return n;
    }
    if (typeof value !== 'string') throw new Error('expected text');
    return value;
  }
  function write(a, t, operation, value) {
    var path = t.path || [];
    if (!path.length) throw new Error('empty path');
    var parent = rootOf(a, t);
    path.slice(0, -1).forEach(function (k) { parent = step(parent, k); });
    var key = path[path.length - 1], old = step(parent, key);
    if (!isLeaf(old)) throw new Error('Only plain values can be edited.');
    if (operation === 'add') value = Number(old) + Number(value);
    if (operation === 'toggle') value = !old;
    value = coerce(old, value);
    if (a.set) a.set(t.root, path, value);
    else if (parent instanceof Map) parent.set(key, value);
    else if (Array.isArray(parent)) parent[Number(key)] = value;
    else parent[key] = value;
    if (a.after) a.after(t.root);
    var reply = { old: old, effective: wire(read(a, t), 2), persistent: !!(a.persistent && a.persistent[t.root]) };
    if (a.note) reply.note = a.note;
    return reply;
  }

  // Frozen values, put back ten times a second while any are held. Live only: the page dies with the session. A
  // target that fails to read or write is dropped rather than retried.
  var MAX_FROZEN = 32, frozen = {}, frozenCount = 0, timer = null;
  function frozenKey(t) { return [t.root].concat(t.path || []).join('\u0000'); }
  function reapply() {
    var a = adapter();
    for (var k in frozen) {
      var f = frozen[k];
      try {
        if (read(a, f.target) !== f.value) write(a, f.target, 'set', f.value);
      } catch (e) {
        delete frozen[k]; frozenCount--;
      }
    }
    if (!frozenCount && timer) { clearInterval(timer); timer = null; }
  }
  function freeze(a, t, value) {
    if (a.persistent && a.persistent[t.root]) throw new Error('Values the game keeps on disk cannot be frozen.');
    var k = frozenKey(t);
    if (!frozen[k] && frozenCount >= MAX_FROZEN) throw new Error('at most ' + MAX_FROZEN + ' values can be frozen');
    var result = write(a, t, 'set', value);
    if (!frozen[k]) frozenCount++;
    frozen[k] = { target: t, value: result.effective };
    if (!timer) timer = setInterval(reapply, 100);
    return result;
  }

  window.__omniplayWebState = function (request) {
    try {
      var a = adapter();
      switch (request.op) {
        case 'list': {
          var all = entries(a, request.category, request.query);
          return { entries: all.slice(request.offset, request.offset + request.size), hasMore: request.offset + request.size < all.length };
        }
        case 'get': {
          var v = read(a, request.target);
          return { entries: [entry(a, request.target, '', v, wire(v, 2))], hasMore: false };
        }
        case 'set': return write(a, request.target, request.operation || 'set', request.value);
        case 'freeze': return freeze(a, request.target, request.value);
        case 'unfreeze': {
          var k = frozenKey(request.target);
          if (frozen[k]) { delete frozen[k]; frozenCount--; }
          return {};
        }
        case 'metadata': return { engine: a.name };
      }
      return { error: 'unknown op ' + request.op };
    } catch (e) {
      return { error: String(e && e.message || e) };
    }
  };
})();
