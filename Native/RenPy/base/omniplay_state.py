# Typed state requests for OmniPlay's Game Tools, in the protocol RuntimeCore's StateWire speaks for every engine:
# {op: "list", category, query, offset, size} | {op: "get", target} | {op: "set", target, operation, value}
# | {op: "metadata"}; replies {entries, hasMore}, {old, effective, persistent} or {error}.
#
# Ren'Py's targets: {kind: "store", store: "store", path: [name, key...]} for variables in renpy.python.store_dicts,
# {kind: "persistent", path: [field, key...]} for renpy.game.persistent, {kind: "label", name} for the script's
# labels (read-only). Only plain leaves (bool, int, float, str) are editable; anything else is reported by type and
# a short repr, never edited. omniplay_host.drain_state calls handle() on the main thread between interactions.
# Python 2.7 and 3 alike: the same file ships in all three engine frameworks.

import json
import math
import sys

PY2 = sys.version_info[0] == 2

if PY2:
    STRINGS = (str, unicode)  # noqa: F821
    INTEGERS = (int, long)  # noqa: F821
else:
    STRINGS = (str,)
    INTEGERS = (int,)

REPR_LIMIT = 200


def handle(raw):
    """One request, as JSON text in and JSON text out. Never raises: an error is a reply."""
    try:
        if not PY2 and isinstance(raw, bytes):
            raw = raw.decode("utf-8")
        request = json.loads(raw)
        if not ready():
            return dump({"error": "notInGame"})
        op = request.get("op")
        if op == "list":
            everything = entries(request.get("category"), request.get("query") or "")
            offset, size = int(request.get("offset") or 0), int(request.get("size") or 200)
            reply = {"entries": everything[offset:offset + size], "hasMore": offset + size < len(everything)}
        elif op == "get":
            target = request["target"]
            reply = {"entries": [entry(target, "", read(target))], "hasMore": False}
        elif op == "set":
            reply = write(request["target"], request.get("operation") or "set", request.get("value"))
        elif op in ("eval", "exec"):
            reply = console(request.get("code") or "", op == "exec")
        elif op == "freeze":
            reply = freeze(request["target"], request.get("value"))
        elif op == "unfreeze":
            _frozen.pop(frozen_key(request["target"]), None)
            reply = {}
        elif op == "loadSlot":
            reply = load_slot(request.get("file") or "")
        elif op == "saveSlot":
            reply = save_slot(request.get("file") or "")
        elif op == "liveTranslation":
            import omniplay_host

            reply = omniplay_host.live_exchange(request.get("deliver") or {})
        elif op == "metadata":
            import renpy

            reply = {
                "name": getattr(renpy.config, "name", ""),
                "version": getattr(renpy.config, "version", ""),
                "renpy": renpy.version_only,
                "stores": sorted(store_names()),
            }
        else:
            reply = {"error": "unknown op %s" % (op,)}
        return dump(reply)
    except (KeyError, ValueError, IndexError) as e:
        # The request asked for something that is not there or cannot be edited: the message says which.
        return dump({"error": "%s: %s" % (type(e).__name__, e)})
    except Exception as e:
        import traceback

        tail = traceback.format_exc().strip().splitlines()[-3:]
        return dump({"error": "%s: %s | %s" % (type(e).__name__, e, " / ".join(t.strip() for t in tail))})


# A slot the host asked to load. Ren'Py loads by unwinding the interaction, so it happens after the reply is out
# (omniplay_host.drain_state calls take_pending_load).
_pending_load = None


def slot_name(file):
    """A save file's slot name: "1-3-LT1.save" is slot "1-3"."""
    name = file.rsplit("/", 1)[-1]
    if not name.endswith("-LT1.save"):
        raise ValueError("%s is not a Ren'Py save" % (file,))
    return name[: -len("-LT1.save")]


def load_slot(file):
    global _pending_load
    import renpy

    slot = slot_name(file)
    if not renpy.exports.can_load(slot):
        return {"error": "Ren'Py cannot load slot %s" % (slot,)}
    _pending_load = slot
    return {}


def save_slot(file):
    import renpy

    # A load rolls back to the start of the saved statement, which would drop edits made during it; this keeps them.
    renpy.exports.retain_after_load()
    renpy.exports.save(slot_name(file), extra_info="OmniPlay edit")
    return {}


def take_pending_load():
    global _pending_load
    slot, _pending_load = _pending_load, None
    return slot


def dump(obj):
    return json.dumps(obj)


def ready():
    """A game is past init and in its script: store variables mean something."""
    import renpy

    try:
        return bool(renpy.game.contexts) and not renpy.game.context().init_phase
    except Exception:
        return False


# ---- Values ----


def plain(value):
    """Plain data the tools can show as JSON. bool before int: a bool is an int in Python."""
    if isinstance(value, float):
        return not (math.isinf(value) or math.isnan(value))  # JSON has no Infinity or NaN
    if value is None or isinstance(value, bool) or isinstance(value, STRINGS):
        return True
    if isinstance(value, INTEGERS):
        return True
    if isinstance(value, (list, tuple)):
        return all(plain(v) for v in value)
    if isinstance(value, dict):
        return all(isinstance(k, STRINGS) and plain(v) for k, v in value.items())
    return False


def leaf(value):
    return value is None or isinstance(value, (bool, float) + STRINGS + INTEGERS)


def entry(target, name, value, persistent=False):
    out = {"target": target, "name": name, "persistent": persistent}
    if plain(value):
        out["value"] = list(value) if isinstance(value, tuple) else value
        out["editable"] = leaf(value) and value is not None
    else:
        try:
            summary = repr(value)
        except Exception:
            summary = "?"
        out["value"] = None
        out["objectType"] = type(value).__name__
        out["summary"] = summary[:REPR_LIMIT]
        out["editable"] = False
    return out


# ---- Where things live ----


def store_names():
    """The game's stores: the main one and named ones (`default x.y`), not Ren'Py's own underscore stores."""
    import renpy

    return [n for n in renpy.python.store_dicts if n == "store" or (n.startswith("store.") and not n.startswith("store._"))]


def store_dict(name):
    import renpy

    d = renpy.python.store_dicts.get(name or "store")
    if d is None:
        raise KeyError("no store %s" % (name,))
    return d


# Engine bookkeeping that Ren'Py assigns at runtime rather than through a `default`: nvl_list is the NVL history,
# rewritten by every NVL line. Documented store variables games set themselves (save_name, main_menu...) stay listed.
ENGINE_NAMES = frozenset([("store", "nvl_list")])

_engine_defaults = (None, frozenset())


def engine_defaults():
    """
    (store, name) for every `default` statement in Ren'Py's own common scripts (nvl_list, the speech bubble store...):
    those are the engine's bookkeeping, not the game's. Computed once per loaded script.
    """
    global _engine_defaults
    import renpy

    script = renpy.game.script
    if _engine_defaults[0] is not script:
        owned = set()
        for node in list(script.namemap.values()):
            if isinstance(node, renpy.ast.Default):
                fn = (getattr(node, "filename", "") or "").replace("\\", "/")
                if fn.startswith("renpy/common/") or "/renpy/common/" in fn:
                    owned.add((node.store, node.varname))
        _engine_defaults = (script, frozenset(owned) | ENGINE_NAMES)
    return _engine_defaults[1]


def game_variables(store, d):
    """
    The names the game itself sets: Ren'Py records every store name changed after init (defaults included) in
    ever_been_changed, which leaves out its own API, the game's functions and characters; the engine's own defaults
    are dropped too. Older engines without it get every name that is not private.
    """
    changed = getattr(d, "ever_been_changed", None)
    names = [n for n in (changed if changed is not None else d.keys()) if n in d]
    owned = engine_defaults()
    return sorted(n for n in names if isinstance(n, STRINGS) and not n.startswith("_") and (store, n) not in owned)


def persistent_fields():
    import renpy

    fields = vars(renpy.game.persistent)
    return sorted(n for n in fields if isinstance(n, STRINGS) and not n.startswith("_"))


def step(container, key):
    if isinstance(container, (list, tuple)):
        return container[int(key)]
    if isinstance(container, dict):
        return container[key]
    return getattr(container, key)


def root_and_path(target):
    import renpy

    kind = target.get("kind")
    path = [p for p in (target.get("path") or [])]
    if not path:
        raise KeyError("empty path")
    if kind == "store":
        return store_dict(target.get("store")), path
    if kind == "persistent":
        return renpy.game.persistent, path
    raise KeyError("not a Ren'Py target: %s" % (kind,))


def read(target):
    import renpy

    if target.get("kind") == "label":
        return renpy.exports.has_label(target.get("name"))
    root, path = root_and_path(target)
    value = root
    for key in path:
        value = step(value, key)
    return value


def assign(container, key, value):
    if isinstance(container, list):
        container[int(key)] = value
    elif isinstance(container, dict):
        container[key] = value
    else:
        setattr(container, key, value)


def coerce(old, value):
    """Keeps the variable's type: an int stays an int, a flag stays a flag."""
    if isinstance(old, bool):
        return bool(value)
    if isinstance(old, INTEGERS) and isinstance(value, (float,) + INTEGERS) and not isinstance(value, bool):
        return int(value)
    if isinstance(old, float) and isinstance(value, INTEGERS + (float,)):
        return float(value)
    if isinstance(old, STRINGS) and not isinstance(value, STRINGS):
        raise ValueError("expected text")
    return value


def write(target, operation, value):
    import renpy

    if target.get("kind") == "label":
        raise ValueError("labels are read-only")
    root, path = root_and_path(target)
    parent = root
    for key in path[:-1]:
        parent = step(parent, key)
    old = step(parent, path[-1])
    if not leaf(old) or old is None:
        raise ValueError("only plain values can be edited (this is %s)" % (type(old).__name__,))
    if operation == "add":
        value = old + value
    elif operation == "toggle":
        value = not old
    value = coerce(old, value)
    if PY2 and isinstance(value, unicode) and isinstance(old, str):  # noqa: F821
        value = value.encode("utf-8")
    assign(parent, path[-1], value)

    persistent = target.get("kind") == "persistent"
    if persistent:
        renpy.exports.save_persistent()
    # Screens showing the value redraw. No checkpoint: a rollback undoes the edit along with the step it lands in,
    # which is what rollback means to the player.
    try:
        renpy.exports.restart_interaction()
    except Exception:
        pass
    return {"old": old, "effective": step(parent, path[-1]), "persistent": persistent}


# ---- Console: the player's own Python, in the store namespace, like Ren'Py's developer console ----

CONSOLE_LIMIT = 4096


def console(code, execute):
    """
    Evaluates an expression or runs statements in the game's store. The result (or the error) comes back as text,
    cut at 4 KiB; an exception is a reply, never a crash. There is no undo: the pre-launch save snapshot is the way back.
    """
    import renpy

    namespace = renpy.store.__dict__
    try:
        if execute:
            exec(compile(code, "<OmniPlay console>", "exec"), namespace)
            result = None
        else:
            result = eval(compile(code.strip(), "<OmniPlay console>", "eval"), namespace)
    except Exception as e:
        import traceback

        lines = traceback.format_exception_only(type(e), e)
        return {"ok": False, "output": "".join(lines).strip()[:CONSOLE_LIMIT]}
    try:
        renpy.exports.restart_interaction()
    except Exception:
        pass
    if execute:
        return {"ok": True, "output": ""}
    try:
        text = repr(result)
    except Exception as e:
        text = "<unprintable %s: %s>" % (type(result).__name__, e)
    return {"ok": True, "output": text[:CONSOLE_LIMIT]}


# ---- Freeze: values put back on every periodic tick (omniplay_host.periodic) until unfrozen ----

MAX_FROZEN = 32
_frozen = {}


def frozen_key(target):
    return json.dumps(target, sort_keys=True)


def freeze(target, value):
    if not leaf(value) or value is None:
        raise ValueError("only plain values can be frozen")
    key = frozen_key(target)
    if key not in _frozen and len(_frozen) >= MAX_FROZEN:
        raise ValueError("at most %d values can be frozen" % MAX_FROZEN)
    result = write(target, "set", value)
    # Held at what the game accepted (the variable's own type), so the hold never fights it.
    _frozen[key] = (target, result["effective"])
    return result


def reapply_frozen():
    for key in list(_frozen):
        target, value = _frozen[key]
        try:
            if read(target) != value:
                root, path = root_and_path(target)
                parent = root
                for k in path[:-1]:
                    parent = step(parent, k)
                assign(parent, path[-1], value)
        except Exception:
            del _frozen[key]


def forget_frozen():
    """A new game starts on this engine: holds belong to the session that set them."""
    _frozen.clear()


# ---- Lists ----


def entries(category, query):
    import renpy

    q = query.lower()

    def wanted(name):
        return not q or q in name.lower()

    out = []
    if category == "store":
        for store in sorted(store_names(), key=lambda n: (n != "store", n)):
            d = store_dict(store)
            prefix = "" if store == "store" else store[len("store."):] + "."
            for name in game_variables(store, d):
                if wanted(prefix + name):
                    out.append(entry({"kind": "store", "store": store, "path": [name]}, prefix + name, d[name]))
    elif category == "persistent":
        fields = vars(renpy.game.persistent)
        for name in persistent_fields():
            if wanted(name):
                out.append(entry({"kind": "persistent", "path": [name]}, name, fields[name], persistent=True))
    elif category == "labels":
        names = [n for n in renpy.exports.get_all_labels() if isinstance(n, STRINGS) and not n.startswith("_")]
        for name in sorted(names):
            if wanted(name):
                out.append({"target": {"kind": "label", "name": name}, "name": name, "value": True, "editable": False})
    else:
        raise ValueError("category not available here: %s" % (category,))
    return out
