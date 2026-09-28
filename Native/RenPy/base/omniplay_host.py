# Everything OmniPlay changes about how an embedded Ren'Py runs, in one place. main.py calls install() before
# Ren'Py starts; omniplay_host.rpy, copied into a host folder on the search path, calls periodic() from the
# game's own interaction loop. Python 2.7 and 3 alike: the same file ships in all three engine frameworks.
#
# The host names the game and its folders in a JSON session it leaves in the framework (op_renpy_session), because
# launcher_main owns argv and Python reads the process environment only once.
#
# One engine plays many games. Python cannot start twice in a process, so leaving a game does not end it: the game
# ends in Ren'Py's own restart loop (UtterRestartException, then renpy.reload_all), and the engine waits in
# get_alternate_base, which that loop calls before every game, until the host names the next one. The exception is
# a session with "keep" false: the host asks for that when this engine started while another one was parked
# beneath it on the main thread, which can only run again once this one has returned.

import gc
import json
import os
import shutil
import sys

COMMAND_RUN, COMMAND_PAUSE, COMMAND_STOP = 0, 1, 2
STATUS_BOOTING, STATUS_RUNNING, STATUS_PAUSED, STATUS_PARKED = 1, 2, 3, 5

# Script sources and the compiled file Ren'Py writes for each, longest suffix first so a .rpym is not read as a
# .rpy. Ren'Py compiles foo_ren.py to foo.rpyc, the same name a foo.rpy would take.
SCRIPT_SOURCES = (("_ren.py", ".rpyc"), (".rpym", ".rpymc"), (".rpy", ".rpyc"))

PY2 = sys.version_info[0] == 2

_library = None
_session = {}
_running = False
_parking = False
_main = None


def env(name, default=None):
    return os.environ.get("OMNIPLAY_RENPY_" + name, default)


def library():
    """The engine framework itself, for the host mailbox in op_renpy.c."""
    global _library
    if _library is None:
        import ctypes

        _library = ctypes.CDLL(env("LIBRARY"))
        _library.op_renpy_idle.argtypes = [ctypes.c_double]
        _library.op_renpy_session.restype = ctypes.c_char_p
        try:
            _library.op_renpy_state_take.restype = ctypes.c_char_p
            _library.op_renpy_state_reply.argtypes = [ctypes.c_char_p]
        except AttributeError:
            pass  # a framework built before the state mailbox
    return _library


def native(s):
    """os.environ takes byte strings on Python 2."""
    if PY2 and not isinstance(s, str):
        return s.encode("utf-8")
    return s


def install():
    import launcher

    # On iOS, Ren'Py puts every game's saves in the app's Documents folder and ignores save_directory; its logs
    # and tracebacks go beside the game, which OmniPlay keeps read-only. Both follow the session instead.
    launcher.path_to_saves = path_to_saves
    launcher.path_to_logdir = path_to_logdir

    global _predefined_searchpath
    _predefined_searchpath = launcher.predefined_searchpath
    launcher.predefined_searchpath = predefined_searchpath

    start_session()

    # Ren'Py's restart loop asks for the game folder here before every game (on iOS, to find downloaded assets).
    import renpy.bootstrap

    renpy.bootstrap.get_alternate_base = alternate_base

    # renpy/common/00iap.rpy looks up the prototype app's IAPHelper class at init on iOS; OmniPlay has none.
    try:
        import pyobjus

        global _autoclass
        _autoclass = pyobjus.autoclass
        pyobjus.autoclass = autoclass
    except ImportError:
        pass

    # Save tokens sign every save with a per-device key and ask before loading one signed elsewhere, which is
    # every save imported from a PC.
    try:
        import renpy.savetoken

        renpy.savetoken.init = token_free_init
    except ImportError:
        pass


def start_session():
    """Points the engine at the game the host named."""
    global _session, _running
    raw = library().op_renpy_session()
    _session = json.loads(raw.decode("utf-8")) if raw else {}
    _running = False

    import iossupport

    iossupport.open_log(_session.get("log"))

    # Until the game's scripts have loaded and initialised, a failure is raised rather than shown on Ren'Py's
    # developer error screen, which would wait for a player who cannot fix it: the game ends at boot, errors.txt
    # keeps the details, and the host falls back to a sibling engine or says what went wrong. omniplay_host.rpy
    # clears this at init 999, so errors during play still get Ren'Py's own screen with Ignore and Rollback.
    os.environ["RENPY_SIMPLE_EXCEPTIONS"] = "1"

    state = sys.modules.get("omniplay_state")
    if state is not None:
        state.forget_frozen()

    # The host script lives in a writable folder, because Ren'Py writes the compiled .rpyc beside it.
    hostdir = _session.get("hostdir")
    if hostdir:
        if not os.path.isdir(hostdir):
            os.makedirs(hostdir)
        here = os.path.dirname(os.path.abspath(__file__))
        shutil.copyfile(os.path.join(here, "omniplay_host.rpy"), os.path.join(hostdir, "omniplay_host.rpy"))
        # The CJK font goes beside it before Ren'Py scans the search path; kept once copied.
        font = _session.get("cjkFont")
        if font and _session.get("translation") and not os.path.exists(os.path.join(hostdir, CJK_FONT_NAME)):
            try:
                shutil.copyfile(font, os.path.join(hostdir, CJK_FONT_NAME))
            except Exception:
                pass
        os.environ["RENPY_SEARCHPATH"] = native(hostdir)
    else:
        os.environ.pop("RENPY_SEARCHPATH", None)


# Everything below that Ren'Py calls is a top-level function: Ren'Py snapshots its modules by pickling their
# globals, and a function pickles only by reference to where it is defined.

_predefined_searchpath = None


def path_to_saves(gamedir, save_directory=None):
    return _session.get("savedir")


def path_to_logdir(basedir):
    return _session.get("logdir") or basedir


def predefined_searchpath(commondir):
    """
    The session's cache folder and the overlay tiers (mods, generated media) go in front of game/, so their files
    win: caches built on this device over any the game shipped, mods over the originals. Ren'Py calls this once
    per game, just before it indexes the search path, which is where the script mirror has to be in place.
    """
    rest = _predefined_searchpath(commondir)
    overlays = list(_session.get("overlays", []))
    cache = _session.get("cachedir")
    if not cache:
        return overlays + rest

    import renpy

    try:
        mirror_scripts(cache, overlays + [renpy.config.gamedir])
    except Exception:
        # A mirror that cannot be built only costs the compile it would have saved; it must not cost the game.
        import traceback

        traceback.print_exc()
    return [cache] + overlays + rest


def mirror_scripts(mirror, dirs):
    """
    Ren'Py compiles every script beside its source, and OmniPlay seals the game's own folder read-only: a game
    that ships .rpy without .rpyc logs a PermissionError per file and parses its whole script set again on every
    launch. Each such source is linked into the session's cache folder, which comes first on the search path, so
    Ren'Py finds the script there, writes the .rpyc next to the link, and the next launch loads what this one
    compiled. A game that ships its .rpyc is left alone and still loads straight from its own folder.

    `dirs` are the search path folders that hold the game's scripts, in the order Ren'Py searches them; the first
    one to claim a name owns it, exactly as Ren'Py's own index does, so a mod still wins over the original.
    """
    wanted = {}
    claimed = set()
    for dn in dirs:
        if not os.path.isdir(dn):
            continue
        for source, compiled in walk_scripts(dn):
            if source in claimed:
                continue
            claimed.add(source)
            if not os.path.exists(os.path.join(dn, compiled)):
                wanted[source] = (os.path.join(dn, source), compiled)

    keep = set()
    for source in sorted(wanted):
        target, compiled = wanted[source]
        link = os.path.join(mirror, source)
        try:
            if not (os.path.islink(link) and os.readlink(link) == target):
                folder = os.path.dirname(link)
                if not os.path.isdir(folder):
                    os.makedirs(folder)
                if os.path.lexists(link):
                    os.remove(link)
                os.symlink(target, link)
            # A mod's script without its compiled file leaves the game's own .rpyc of that name visible further down
            # the search path, and Ren'Py would load both ("given a default a second time"). An empty file claims the
            # name first; Ren'Py reads no digest from it, so it compiles the source and writes over it.
            placeholder = os.path.join(mirror, compiled)
            if not os.path.exists(placeholder):
                open(placeholder, "wb").close()
        except OSError:
            continue
        keep.add(source)
        keep.add(compiled)
    prune_scripts(mirror, keep)


def walk_scripts(folder):
    """Yields (source, compiled) names, relative to `folder`, for every script source under it."""
    for here, subdirs, files in os.walk(folder):
        subdirs[:] = [d for d in subdirs if not d.startswith(".")]
        at = os.path.relpath(here, folder)
        at = "" if at == "." else at + "/"
        for name in files:
            for suffix, compiled in SCRIPT_SOURCES:
                if name.endswith(suffix):
                    yield at + name, at + name[: -len(suffix)] + compiled
                    break


def prune_scripts(mirror, keep):
    """
    Drops the links, and the compiled files beside them, for scripts the game no longer has. A dangling link is
    worse than no link: Ren'Py would fall back to the stale .rpyc next to it and play a script that is gone.
    """
    suffixes = tuple(suffix for pair in SCRIPT_SOURCES for suffix in pair)
    for here, subdirs, files in os.walk(mirror):
        subdirs[:] = [d for d in subdirs if not d.startswith(".")]
        at = os.path.relpath(here, mirror)
        at = "" if at == "." else at + "/"
        for name in files:
            if name.endswith(suffixes) and at + name not in keep:
                try:
                    os.remove(os.path.join(here, name))
                except OSError:
                    pass


def cache_path(fn):
    """
    Replaces renpy.loader.get_path, the one place Ren'Py asks where to write its caches (compiled Python bytecode,
    script analysis, shaders). The game folder is read-only; the session's cache folder is writable and searched
    first, so the next launch reads what this one wrote instead of compiling again.
    """
    fn = os.path.join(_session["cachedir"], fn)
    try:
        os.makedirs(os.path.dirname(fn))
    except OSError:
        pass
    return fn


_elide_filename = None


def install_elide():
    global _elide_filename
    import renpy.lexer

    if renpy.lexer.elide_filename is not elide_filename:
        _elide_filename = renpy.lexer.elide_filename
        renpy.lexer.elide_filename = elide_filename


def elide_filename(fn):
    """
    Replaces renpy.lexer.elide_filename. Ren'Py names a script's nodes, and the prefix that mangles its __names,
    after the file's path inside the game, and both go into save files. A script Ren'Py read through the mirror
    (mirror_scripts) sits outside the game, so it is named as if it were still in game/: the cache folder is a
    path with the app's container id in it, which a reinstall changes, and saves must outlive that.
    """
    import renpy

    cache = _session.get("cachedir")
    if cache:
        # The session's folders arrive with a trailing slash, so Ren'Py's own dir + "/" + fn leaves a double one.
        prefix = cache.replace("\\", "/").rstrip("/") + "/"
        inside = fn.replace("\\", "/")
        if inside.startswith(prefix):
            return _elide_filename(os.path.join(renpy.config.gamedir, inside[len(prefix):].lstrip("/")))
    return _elide_filename(fn)


def alternate_base(basedir, always=False):
    """
    Ren'Py's bootstrap loop calls this before every game. The first time, the game is the one on the command line.
    After a game ends, the engine waits here for the host's next one.
    """
    global _parking
    import renpy.main

    # The loop calls renpy.main.main through the module, so wrapping it here covers every game.
    global _main
    if renpy.main.main is not run_game:
        _main = renpy.main.main
        renpy.main.main = run_game

    if _parking:
        _parking = False
        # Nothing here may raise: Ren'Py's loop would swallow it and silently restart the last game unparked.
        try:
            forget_game(basedir)
        except Exception:
            import traceback

            traceback.print_exc()
        park()
        start_session()
        library().op_renpy_set_status(STATUS_BOOTING)

    import renpy.loader

    if _session.get("cachedir"):
        renpy.loader.get_path = cache_path
        install_elide()
    return _session.get("basedir") or basedir


def run_game():
    """
    Runs one game. However it ends (its own menu, the host asking, a script that fails to load), the engine is
    kept: the ending becomes Ren'Py's utter restart, which reloads Ren'Py and comes back to alternate_base for the
    next game. Left to Ren'Py, a load error would end Python and spend the engine for every other game.
    """
    global _parking
    import renpy

    keep = _session.get("keep", True)
    try:
        _main()
    except renpy.game.QuitException as e:
        # A game that asks to relaunch itself starts over in place; subprocess cannot start a copy on iOS.
        if not keep and not e.relaunch:
            raise
        _parking = not e.relaunch
    except renpy.game.ParseErrorException:
        if not keep:
            raise
        _parking = True
    except Exception as e:
        if not keep:
            raise
        # Writes traceback.txt into the session's log folder (path_to_logdir), as Ren'Py's own loop would.
        try:
            renpy.error.report_exception(e, False)
        except Exception:
            import traceback

            traceback.print_exc()
        _parking = True
    renpy.session["_keep_renderer"] = False
    raise renpy.game.UtterRestartException()


def forget_game(basedir):
    """
    Clears what Ren'Py's reload keeps on purpose because it expects the same game back: the Python modules the game
    imported (the next game could pick up one of the same name) and the registered test cases (a second game's
    `global` suite is refused as a duplicate).
    """
    test = sys.modules.get("renpy.test.testexecution")
    if test is not None:
        test.testcases.clear()
        if hasattr(test, "global_test_suite"):
            test.global_test_suite = None

    prefix = os.path.join(_session.get("basedir") or basedir, "")
    for name, module in list(sys.modules.items()):
        # The module's own dict, not getattr: placeholders such as pygame_sdl2's for a submodule it lacks raise
        # on any attribute they do not have.
        try:
            attrs = vars(module)
        except TypeError:
            continue
        path = attrs.get("__file__") or ""
        if type(attrs.get("__loader__")).__name__ == "RenpyImporter" or path.startswith(prefix):
            del sys.modules[name]
    gc.collect()


def park():
    """Holds the engine, with the host's UI alive, until the host names another game."""
    lib = library()
    lib.op_renpy_request(COMMAND_STOP)
    lib.op_renpy_set_status(STATUS_PARKED)
    sys.stdout.write("OmniPlay: game ended; engine parked\n")
    while lib.op_renpy_command() != COMMAND_RUN:
        lib.op_renpy_idle(0.1)


_previous_open = None


def switches():
    """The player's developer switches for this game (Ren'Py Tools), applied by omniplay_host.rpy at init 999."""
    return _session.get("switches") or {}


_dictionary = None
DICTIONARY_LIMIT = 64 << 20
# Live translation (TRANS-006): lines the dictionary missed wait in _missed until the host collects them through the
# state mailbox, and its translations land in _live; a line is asked about once per game.
_live = {}
_asked = set()
_missed = []
ASK_LIMIT = 5000


def load_translation():
    """
    The session's MTool dictionary ({original: translation}), read once per game within 64 MiB. True when the text
    filter is needed: a dictionary, or live translation on.
    """
    global _dictionary
    _dictionary = None
    _live.clear()
    _asked.clear()
    del _missed[:]
    path = _session.get("translation")
    if path:
        try:
            if os.path.getsize(path) > DICTIONARY_LIMIT:
                sys.stdout.write("OmniPlay: translation dictionary too large\n")
            else:
                # Bytes, the BOM dropped by hand and plain UTF-8: Python 2's embedded codecs have no "utf-8-sig".
                with open(path, "rb") as f:
                    data = f.read()
                if data[:3] == b"\xef\xbb\xbf":
                    data = data[3:]
                loaded = json.loads(data.decode("utf-8"))
                if isinstance(loaded, dict):
                    _dictionary = loaded
                    sys.stdout.write("OmniPlay: translation dictionary, %d entries\n" % len(loaded))
        except Exception as e:
            sys.stdout.write("OmniPlay: translation dictionary unreadable: %r\n" % (e,))
    return bool(_dictionary) or bool(_session.get("liveTranslation"))


def translate_text(s):
    """config.say_menu_text_filters: whole text first, then line by line; a miss goes to live translation, if on."""
    d = _dictionary or {}
    t = d.get(s)
    if t is not None:
        return t
    if "\n" in s:
        lines = s.split("\n")
        out = [d.get(line, line) for line in lines]
        if out != lines:
            return "\n".join(out)
    if not _session.get("liveTranslation"):
        return s
    t = _live.get(s)
    if t is not None:
        return t
    if s.strip() and s not in _asked and len(_asked) < ASK_LIMIT:
        _asked.add(s)
        _missed.append(s)
    return s


def live_exchange(deliver):
    """The host's half-second visit: its translations in, the lines missed since the last visit out."""
    if deliver:
        _live.update(deliver)
        try:
            import renpy

            renpy.exports.restart_interaction()  # the line on screen is drawn again, translated
        except Exception:
            pass
    missed = _missed[:]
    del _missed[:]
    return {"missed": missed}


def chain_text_filter(previous):
    """Ren'Py 7's single say_menu_text_filter: the dictionary first, then whatever the game had."""
    if previous is None:
        return translate_text
    return lambda s: previous(translate_text(s))


CJK_FONT_NAME = "omniplay_cjk.ttf"
# Chinese, Japanese and Korean ranges: CJK punctuation and kana through the unified ideographs, Hangul syllables,
# compatibility ideographs and full-width forms.
CJK_RANGES = ((0x2E80, 0x9FFF), (0xAC00, 0xD7AF), (0xF900, 0xFAFF), (0xFF00, 0xFFEF))


def cjk_font():
    """The CJK font's name on the search path when the active dictionary's translations are CJK, else None."""
    hostdir = _session.get("hostdir")
    if not _dictionary or not hostdir or not os.path.exists(os.path.join(hostdir, CJK_FONT_NAME)):
        return None
    for count, text in enumerate(_dictionary.values()):
        if count >= 200:
            break
        for ch in text:
            code = ord(ch)
            if any(lo <= code <= hi for lo, hi in CJK_RANGES):
                return CJK_FONT_NAME
    return None


def apply_cjk_font(styles, font_group, cjk):
    """Every style's font becomes a FontGroup: CJK ranges from `cjk`, everything else from the font it had."""
    groups = {}
    for style in list(styles.values()):
        try:
            original = style.font
            key = id(original)
            if key not in groups:
                group = font_group()
                for lo, hi in CJK_RANGES:
                    group.add(cjk, lo, hi)
                group.add(original, None, None)
                groups[key] = group
            style.font = groups[key]
        except Exception:
            pass


def language():
    return _session.get("language") or None


def has_media_remap():
    return bool(_session.get("remap"))


def chain_open(previous):
    global _previous_open
    _previous_open = previous if previous is not open_media else _previous_open


def open_media(name):
    """
    config.file_open_callback: media converted before launch because this engine cannot decode it (H.264 video, AAC
    audio...) is opened under the name the game uses. The converted Theora or Vorbis file sits in the Generated layer.
    """
    target = _session.get("remap", {}).get(name.replace("\\", "/").lower())
    if target:
        # The engine's own file type (an SDL RWops): its audio and movie decoders read a plain Python file through a
        # wrapper that sees it closed before the first read.
        import renpy.loader

        return renpy.loader.open_file(target, "rb")
    if _previous_open is not None:
        return _previous_open(name)
    return None


def hint_converted_images(pgrender):
    """
    Ren'Py hands SDL_image the file name as a format hint, and SDL_image tries the formats that have no signature
    (TGA) by that hint alone. A converted image is PNG under its old name, so the hint has to follow the conversion.
    """
    load_image = pgrender.load_image

    def load_converted(f, filename, size=None):
        target = _session.get("remap", {}).get(filename.replace("\\", "/").lower()) if hasattr(filename, "lower") else None
        if target:
            filename = filename.rpartition(".")[0] + "." + target.rpartition(".")[2]
        return load_image(f, filename, size=size)

    pgrender.load_image = load_converted
    pgrender.load_image_unscaled = load_converted


_autoclass = None


def autoclass(name, *args, **kwargs):
    if name == "IAPHelper":
        return NoAppStore
    return _autoclass(name, *args, **kwargs)


class NoAppStore(object):
    """
    Stands in for the prototype app's StoreKit helper. OmniPlay sells nothing, so the store is never available:
    Ren'Py's iap module then reports no store, and a game's purchase screens stay closed.
    """

    productIdentifiers = None
    dialogTitle = None
    finished = 1

    @classmethod
    def alloc(cls):
        return cls()

    def init(self):
        return self

    def canMakePayments(self):
        return False

    def validateProductIdentifiers(self):
        pass

    def beginPurchase_(self, identifier):
        pass

    def restorePurchases(self):
        pass

    def hasPurchased_(self, identifier):
        return False

    def hasPurchasedConsumable_(self, identifier):
        return False

    def isDeferred_(self, identifier):
        return False

    def formatPrice_(self, identifier):
        return None

    def requestReview(self):
        pass


def token_free_init():
    """
    Replaces renpy.savetoken.init. With no token directory Ren'Py accepts any save, and should_upgrade makes it
    accept unsigned persistent data: the state Ren'Py itself runs in for games that predate save tokens.
    """
    import renpy.savetoken as savetoken

    savetoken.token_dir = None
    savetoken.signing_keys = []
    savetoken.verifying_keys = []
    savetoken.should_upgrade = True


def periodic():
    """Called about twenty times a second from the game's interaction loop."""
    global _running

    lib = library()
    command = lib.op_renpy_command()

    if command == COMMAND_PAUSE:
        pause(lib)
        command = lib.op_renpy_command()

    if command == COMMAND_STOP:
        import renpy

        raise renpy.game.QuitException()

    if not _running:
        _running = True
        lib.op_renpy_set_status(STATUS_RUNNING)

    drain_state(lib)


def drain_state(lib):
    """Answers the Game Tools' pending state request, if there is one (op_renpy_state_*, omniplay_state)."""
    take = getattr(lib, "op_renpy_state_take", None)
    raw = take() if take is not None else None
    if raw:
        import omniplay_state

        lib.op_renpy_state_reply(omniplay_state.handle(raw).encode("utf-8"))
        slot = omniplay_state.take_pending_load()
        if slot is not None:
            import renpy

            # Unwinds the interaction (and the pause loop, which pauses again on the next tick) into the loaded game.
            renpy.exports.load(slot)
    state = sys.modules.get("omniplay_state")
    if state is not None and state._frozen:
        state.reapply_frozen()


def pause(lib):
    """Holds the game until the host resumes or stops it, keeping the host's UI alive meanwhile."""
    import renpy

    snapshot = _session.get("snapshot")
    if snapshot:
        try:
            renpy.exports.screenshot(snapshot)
        except Exception:
            pass

    renpy.audio.audio.pause_all()
    lib.op_renpy_set_status(STATUS_PAUSED)

    try:
        while lib.op_renpy_command() == COMMAND_PAUSE:
            lib.op_renpy_idle(0.05)
            # The Game Tools open from the pause menu, so their requests are answered while paused too.
            drain_state(lib)
    finally:
        renpy.audio.audio.unpause_all()
        lib.op_renpy_set_status(STATUS_RUNNING)


def exited(code):
    sys.stdout.write("OmniPlay: Ren'Py exited with status %r\n" % (code,))
