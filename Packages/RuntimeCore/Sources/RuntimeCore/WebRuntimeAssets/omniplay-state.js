// omniplay-state.js — typed state access for RPG Maker MV/MZ, in the page world where $game* lives. The host calls
// window.__omniplayState(request) through callAsyncJavaScript and gets plain JSON back. Nothing here runs by itself.
//
// Request: {op: "list", category, query, offset, size} | {op: "get", target} | {op: "set", target, operation, value}
//          | {op: "freeze", target, value} | {op: "unfreeze", target} | {op: "metadata"}
// Target:  {kind: "variable"|"switch"|"gold"|"item"|"weapon"|"armor"|"partyMember"|"actor"|"system"|"position"
//           |"selfSwitch"|"patch", id, prop, param, map, event, key, flag, name}
// Patches are named, typed changes to the game's behaviour for the cheat catalog (never code from the host):
// noEncounters, noclip, godMode (on/off) and debugMenu (setting it opens the game's own debug scene).
(function () {
  'use strict';
  if (window.__omniplayState) return;

  function ready() {
    return typeof $gameSystem !== 'undefined' && $gameSystem && typeof $gameParty !== 'undefined' && $gameParty &&
      typeof $dataSystem !== 'undefined' && $dataSystem;
  }
  function itemTable(kind) {
    return kind === 'weapon' ? $dataWeapons : kind === 'armor' ? $dataArmors : $dataItems;
  }
  function name(value, fallback) { return value && String(value).trim() ? String(value) : fallback; }

  // Session-only flags live outside actors so saves never persist invulnerability. A character override can
  // disable protection even when party mode was enabled. Party mode explicitly resets all overrides.
  var patches = { canEncounter: null, god: false, godHooked: false, godActors: Object.create(null) };
  function actorGodMode(id) {
    return Object.prototype.hasOwnProperty.call(patches.godActors, id) ? patches.godActors[id] : patches.god;
  }
  function partyGodMode() {
    var members = $gameParty.members();
    return members.length > 0 && members.every(function (a) { return actorGodMode(a.actorId()); });
  }
  function hookGodMode() {
    if (patches.godHooked) return;
    patches.godHooked = true;
    var setHp = Game_Actor.prototype.setHp, addState = Game_Actor.prototype.addState;
    Game_Actor.prototype.setHp = function (hp) {
      return setHp.call(this, actorGodMode(this.actorId()) ? Math.max(hp, this.hp) : hp);
    };
    Game_Actor.prototype.addState = function (id) {
      if (!actorGodMode(this.actorId()) || id !== this.deathStateId()) return addState.call(this, id);
    };
    // Scripted knockout and the engine's direct death-state path can bypass addState.
    ['die', 'addNewState'].forEach(function (method) {
      var original = Game_Actor.prototype[method];
      if (typeof original !== 'function') return;
      Game_Actor.prototype[method] = function (id) {
        if (actorGodMode(this.actorId()) && (method === 'die' || id === this.deathStateId())) return;
        return original.apply(this, arguments);
      };
    });
  }
  function readPatch(name) {
    switch (name) {
      case 'noEncounters': return patches.canEncounter !== null;
      case 'noclip': return $gamePlayer.isThrough();
      case 'godMode': return partyGodMode();
      case 'debugMenu':
        return typeof Scene_Debug !== 'undefined' &&
          (SceneManager._nextScene instanceof Scene_Debug || SceneManager._scene instanceof Scene_Debug);
    }
    throw new Error('unknown patch ' + name);
  }
  function writePatch(name, on) {
    switch (name) {
      case 'noEncounters':
        if (on && patches.canEncounter === null) {
          patches.canEncounter = Game_Player.prototype.canEncounter;
          Game_Player.prototype.canEncounter = function () { return false; };
        } else if (!on && patches.canEncounter !== null) {
          Game_Player.prototype.canEncounter = patches.canEncounter;
          patches.canEncounter = null;
        }
        return;
      case 'noclip': $gamePlayer.setThrough(on); return;
      case 'godMode':
        hookGodMode();
        patches.god = on;
        patches.godActors = Object.create(null);
        return;
      case 'debugMenu':
        if (on && typeof Scene_Debug !== 'undefined') { $gameTemp._isPlaytest = true; SceneManager.push(Scene_Debug); }
        return;
    }
    throw new Error('unknown patch ' + name);
  }

  function read(t) {
    switch (t.kind) {
      case 'patch': return readPatch(t.name);
      case 'variable': return $gameVariables.value(t.id);
      case 'switch': return $gameSwitches.value(t.id);
      case 'selfSwitch': return $gameSelfSwitches.value([t.map, t.event, t.key]);
      case 'gold': return $gameParty.gold();
      case 'item': case 'weapon': case 'armor': {
        var item = itemTable(t.kind)[t.id];
        if (!item) throw new Error('no ' + t.kind + ' ' + t.id);
        return $gameParty.numItems(item);
      }
      case 'partyMember': return $gameParty._actors.indexOf(t.id) >= 0;
      case 'actor': {
        var a = $gameActors.actor(t.id);
        if (!a) throw new Error('no actor ' + t.id);
        switch (t.prop) {
          case 'hp': return a.hp;
          case 'mp': return a.mp;
          case 'tp': return a.tp;
          case 'level': return a.level;
          case 'exp': return a.currentExp();
          case 'name': return a.name();
          case 'godMode': return actorGodMode(t.id);
          case 'param': return a.param(t.param);
          case 'skill': return a.isLearnedSkill(t.param);
        }
        throw new Error('unknown actor property ' + t.prop);
      }
      case 'system': {
        switch (t.flag) {
          case 'saveEnabled': return $gameSystem.isSaveEnabled();
          case 'encounterEnabled': return $gameSystem.isEncounterEnabled();
          case 'menuEnabled': return $gameSystem.isMenuEnabled();
        }
        throw new Error('unknown system flag ' + t.flag);
      }
      case 'position': return { map: $gameMap.mapId(), x: $gamePlayer.x, y: $gamePlayer.y };
    }
    throw new Error('unknown target ' + t.kind);
  }

  function write(t, operation, value) {
    var old = read(t);
    if (operation === 'add') value = Number(old) + Number(value);
    if (operation === 'toggle') value = !old;
    switch (t.kind) {
      case 'patch': writePatch(t.name, !!value); break;
      case 'variable': $gameVariables.setValue(t.id, value); break;
      case 'switch': $gameSwitches.setValue(t.id, !!value); break;
      case 'selfSwitch': $gameSelfSwitches.setValue([t.map, t.event, t.key], !!value); break;
      case 'gold': $gameParty.gainGold(Math.round(Number(value)) - $gameParty.gold()); break;
      case 'item': case 'weapon': case 'armor': {
        var item = itemTable(t.kind)[t.id];
        $gameParty.gainItem(item, Math.round(Number(value)) - $gameParty.numItems(item), false);
        break;
      }
      case 'partyMember': if (value) $gameParty.addActor(t.id); else $gameParty.removeActor(t.id); break;
      case 'actor': {
        var a = $gameActors.actor(t.id);
        switch (t.prop) {
          case 'hp': a.setHp(Math.round(Number(value))); break;
          case 'mp': a.setMp(Math.round(Number(value))); break;
          case 'tp': a.setTp(Math.round(Number(value))); break;
          case 'level': a.changeLevel(Math.round(Number(value)), false); break;
          case 'exp': a.changeExp(Math.round(Number(value)), false); break;
          case 'name': a.setName(String(value)); break;
          case 'godMode': hookGodMode(); patches.godActors[t.id] = !!value; break;
          case 'param': a.addParam(t.param, Math.round(Number(value)) - a.param(t.param)); break;
          case 'skill': if (value) a.learnSkill(t.param); else a.forgetSkill(t.param); break;
          default: throw new Error('unknown actor property ' + t.prop);
        }
        break;
      }
      case 'system': {
        var on = !!value;
        if (t.flag === 'saveEnabled') { on ? $gameSystem.enableSave() : $gameSystem.disableSave(); }
        else if (t.flag === 'encounterEnabled') { on ? $gameSystem.enableEncounter() : $gameSystem.disableEncounter(); }
        else if (t.flag === 'menuEnabled') { on ? $gameSystem.enableMenu() : $gameSystem.disableMenu(); }
        break;
      }
      case 'position': $gamePlayer.locate(Math.round(value.x), Math.round(value.y)); break;
      default: throw new Error('unknown target ' + t.kind);
    }
    return { old: old, effective: read(t) };
  }

  function entries(category, query) {
    var out = [], q = (query || '').toLowerCase();
    function add(target, label, editable) {
      if (q && label.toLowerCase().indexOf(q) < 0 && String(target.id) !== q) return;
      out.push({ target: target, name: label, value: read(target), editable: editable !== false });
    }
    var i;
    switch (category) {
      case 'variables':
        for (i = 1; i < $dataSystem.variables.length; i++) add({ kind: 'variable', id: i }, name($dataSystem.variables[i], 'Variable ' + i));
        break;
      case 'switches':
        for (i = 1; i < $dataSystem.switches.length; i++) add({ kind: 'switch', id: i }, name($dataSystem.switches[i], 'Switch ' + i));
        break;
      case 'items': case 'weapons': case 'armors': {
        var kind = category.slice(0, -1), table = itemTable(kind);
        for (i = 1; i < table.length; i++) if (table[i] && table[i].name) add({ kind: kind, id: i }, table[i].name);
        break;
      }
      case 'party':
        for (i = 1; i < $dataActors.length; i++) if ($dataActors[i]) add({ kind: 'partyMember', id: i }, name($dataActors[i].name, 'Actor ' + i));
        break;
      case 'actors':
        $gameParty.members().forEach(function (a) {
          ['hp', 'mp', 'tp', 'level', 'exp'].forEach(function (p) {
            add({ kind: 'actor', id: a.actorId(), prop: p }, a.name() + ' ' + p.toUpperCase());
          });
        });
        break;
      case 'system':
        add({ kind: 'gold' }, 'Gold');
        ['saveEnabled', 'encounterEnabled', 'menuEnabled'].forEach(function (f) { add({ kind: 'system', flag: f }, f); });
        add({ kind: 'position' }, 'Player position');
        break;
      default:
        throw new Error('category not available here: ' + category);
    }
    return out;
  }

  // Frozen values, put back once per frame by a SceneManager.updateMain wrapper when the game changes them. Live
  // only: the page dies with the session. A target that fails to read or write is dropped rather than retried.
  var MAX_FROZEN = 32, frozen = {}, frozenCount = 0, hooked = false;
  // Field by field: the host's JSON does not keep key order, so JSON.stringify would not match between requests.
  function frozenKey(t) { return [t.kind, t.id, t.prop, t.param, t.flag, t.map, t.event, t.key, t.name].join('|'); }
  function reapplyFrozen() {
    for (var k in frozen) {
      var f = frozen[k];
      try {
        if (read(f.target) !== f.value) write(f.target, 'set', f.value);
      } catch (e) {
        delete frozen[k]; frozenCount--;
      }
    }
  }
  function hookFrames() {
    if (hooked || typeof SceneManager === 'undefined') return;
    var update = SceneManager.updateMain;
    SceneManager.updateMain = function () {
      update.apply(this, arguments);
      if (frozenCount) reapplyFrozen();
    };
    hooked = true;
  }
  function freeze(t, value) {
    if (value === null || typeof value === 'object') throw new Error('only plain values can be frozen');
    var k = frozenKey(t);
    if (!frozen[k] && frozenCount >= MAX_FROZEN) throw new Error('at most ' + MAX_FROZEN + ' values can be frozen');
    var result = write(t, 'set', value);
    if (!frozen[k]) frozenCount++;
    // Held at what the game accepted (a clamped value), so the hold does not fight the engine's own caps.
    frozen[k] = { target: t, value: result.effective };
    hookFrames();
    return result;
  }

  window.__omniplayState = function (request) {
    try {
      if (!ready()) return { error: 'notInGame' };
      switch (request.op) {
        case 'list': {
          var all = entries(request.category, request.query);
          var page = all.slice(request.offset, request.offset + request.size);
          return { entries: page, hasMore: request.offset + request.size < all.length };
        }
        case 'get': return { entries: [{ target: request.target, name: '', value: read(request.target), editable: true }], hasMore: false };
        case 'set': return write(request.target, request.operation || 'set', request.value);
        case 'freeze': return freeze(request.target, request.value);
        case 'unfreeze': {
          var k = frozenKey(request.target);
          if (frozen[k]) { delete frozen[k]; frozenCount--; }
          return {};
        }
        case 'metadata':
          return { variables: $dataSystem.variables, switches: $dataSystem.switches, title: $dataSystem.gameTitle };
      }
      return { error: 'unknown op ' + request.op };
    } catch (e) {
      return { error: String(e && e.message || e) };
    }
  };
})();
