#!/usr/bin/env python3
"""Deterministic synthetic fixtures for detection and import tests. Standard library only, no game
content: every file is a structural stub with the right magic bytes and names. Fixed timestamps and
a fixed random seed make the output hash-identical across runs; MANIFEST.sha256 pins it.

usage: make-fixtures.py            regenerate Fixtures/synthetic and MANIFEST.sha256
"""
import hashlib, io, json, os, random, shutil, struct, sys, tarfile, zipfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Fixtures", "synthetic")
ROOT = os.path.normpath(ROOT)
TS = (2026, 1, 1, 0, 0, 0)
MTIME = 1767225600  # 2026-01-01T00:00:00Z
rnd = random.Random(20260101)

def w(rel, data=b""):
    path = os.path.join(ROOT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data if isinstance(data, bytes) else data.encode("utf-8"))
    os.utime(path, (MTIME, MTIME))
    return path

def pe_stub(extra_sections=0):
    """Minimal PE32: DOS header, PE signature at 0x40, one .text section whose raw data ends at 0x400.
    Anything appended after 0x400 is the overlay (nw.js payloads, Godot PCK tails, SFX archives)."""
    dos = bytearray(64); dos[0:2] = b"MZ"; struct.pack_into("<I", dos, 0x3C, 0x40)
    coff = struct.pack("<HHIIIHH", 0x014C, 1, MTIME, 0, 0, 0xE0, 0x0102)
    opt = bytearray(0xE0); struct.pack_into("<H", opt, 0, 0x10B)
    struct.pack_into("<I", opt, 16, 0x1000)   # AddressOfEntryPoint
    struct.pack_into("<I", opt, 28, 0x400000) # ImageBase
    struct.pack_into("<I", opt, 32, 0x1000)   # SectionAlignment
    struct.pack_into("<I", opt, 36, 0x200)    # FileAlignment
    struct.pack_into("<H", opt, 68, 2)        # Subsystem GUI
    sect = struct.pack("<8sIIIIIIHHI", b".text", 0x200, 0x1000, 0x200, 0x200, 0, 0, 0, 0, 0x60000020)
    head = bytes(dos) + b"PE\0\0" + coff + bytes(opt) + sect
    head += b"\0" * (0x200 - len(head))
    return head + b"\x90" * 0x200

PE = pe_stub()
def ebml(eid, payload):
    """EBML element: id bytes + 8-byte size vint + payload."""
    return eid + bytes([0x01]) + len(payload).to_bytes(7, "big") + payload

def webm_bytes(video="V_VP9", audio="A_VORBIS"):
    header = ebml(b"\x1a\x45\xdf\xa3", ebml(b"\x42\x86", b"\x01") + ebml(b"\x42\xf7", b"\x01") + ebml(b"\x42\x82", b"webm") + ebml(b"\x42\x87", b"\x04"))
    def track(n, ttype, codec):
        return ebml(b"\xae", ebml(b"\xd7", bytes([n])) + ebml(b"\x83", bytes([ttype])) + ebml(b"\x86", codec.encode()))
    tracks = ebml(b"\x16\x54\xae\x6b", track(1, 1, video) + track(2, 2, audio))
    segment = ebml(b"\x18\x53\x80\x67", ebml(b"\x15\x49\xa9\x66", ebml(b"\x2a\xd7\xb1", (1000000).to_bytes(4, "big"))) + tracks)
    return header + segment + bytes(64)

def box(kind, payload=b""):
    return struct.pack(">I", 8 + len(payload)) + kind + payload

def mp4_bytes(video="avc1", audio="mp4a", brand=b"isom", moov_at_end=False):
    ftyp = box(b"ftyp", brand + b"\0\0\x02\0" + b"isomiso2avc1mp41")
    def trak(fourcc):
        entry = box(fourcc.encode(), bytes(78))
        stsd = box(b"stsd", b"\0\0\0\0" + struct.pack(">I", 1) + entry)
        return box(b"trak", box(b"mdia", box(b"minf", box(b"stbl", stsd))))
    moov = box(b"moov", box(b"mvhd", bytes(100)) + trak(video) + trak(audio))
    mdat = box(b"mdat", bytes(256))
    return ftyp + (mdat + moov if moov_at_end else moov + mdat)

WEBM = webm_bytes()
MP4 = mp4_bytes()
M4A = mp4_bytes(video="mp4a", audio="mp4a", brand=b"M4A ")
OGG = b"OggS\x00\x02" + b"\0" * 20 + b"\x01\x1e" + b"\x01vorbis" + b"\0" * 23
PNG = b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0) + b"\0" * 4 + struct.pack(">I", 0) + b"IEND\xaeB`\x82"

class RawNameZipInfo(zipfile.ZipInfo):
    """Writes the entry name bytes verbatim with the UTF-8 flag clear (CP932 fixtures)."""
    raw = b""
    def _encodeFilenameFlags(self):
        return self.raw, self.flag_bits & ~0x800

def zip_write(path, entries, comment=None, compression=zipfile.ZIP_DEFLATED, raw_names=False):
    """entries: list of (name, bytes). Names are stored as given; raw_names keeps CP932 bytes and clears the UTF-8 flag."""
    with zipfile.ZipFile(path, "w") as zf:
        for name, data in entries:
            zi = (RawNameZipInfo if raw_names else zipfile.ZipInfo)(name, date_time=TS)
            zi.compress_type = compression
            zi.external_attr = 0o644 << 16
            if raw_names:
                zi.raw = name.encode("cp437")
            zf.writestr(zi, data)
        if comment:
            zf.comment = comment
    os.utime(path, (MTIME, MTIME))

def zip_bytes(entries):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        for name, data in entries:
            zi = zipfile.ZipInfo(name, date_time=TS); zi.compress_type = zipfile.ZIP_DEFLATED; zi.external_attr = 0o644 << 16
            zf.writestr(zi, data)
    return buf.getvalue()

def gdpc(major, minor, patch, fmt=2, flags=0):
    """Godot PCK header: magic, pack format, engine version, flags/offset (format 2), 16 reserved u32, file count."""
    h = b"GDPC" + struct.pack("<IIII", fmt, major, minor, patch)
    if fmt >= 2:
        h += struct.pack("<IQ", flags, 0)
    h += b"\0" * 64 + struct.pack("<I", 0)
    return h + b"\0" * 64

def system_json(encrypted):
    d = {"gameTitle": "Synthetic MV", "versionId": 1, "locale": "en_US", "hasEncryptedImages": encrypted,
         "hasEncryptedAudio": encrypted, "sounds": [], "switches": [""], "variables": [""]}
    if encrypted:
        d["encryptionKey"] = "0123456789abcdef0123456789abcdef"
    return json.dumps(d, sort_keys=True, separators=(",", ":"))

def mv_tree(prefix, encrypted=False):
    w(f"{prefix}/www/index.html", "<!DOCTYPE html><html><head><title>MV</title></head><body><script src='js/main.js'></script></body></html>")
    w(f"{prefix}/www/js/rpg_core.js", "//=============================================================================\n// rpg_core.js v1.6.2\nfunction Utils() {}\nUtils.RPGMAKER_NAME = \"MV\";\nUtils.RPGMAKER_VERSION = \"1.6.2\";\n")
    w(f"{prefix}/www/js/plugins.js", "var $plugins =\n[\n{\"name\":\"Community_Basic\",\"status\":true,\"description\":\"\",\"parameters\":{}}\n];\n")
    w(f"{prefix}/www/js/main.js", "PluginManager.setup($plugins);\n")
    w(f"{prefix}/www/data/System.json", system_json(encrypted))
    w(f"{prefix}/www/movies/intro.webm", WEBM)
    w(f"{prefix}/www/movies/intro.mp4", MP4)
    w(f"{prefix}/www/audio/bgm/a.ogg", OGG)
    w(f"{prefix}/www/audio/bgm/a.m4a", M4A)
    w(f"{prefix}/www/audio/me/fanfare.mp3", b"ID3\x04\x00\x00\x00\x00\x00\x00" + bytes(32))
    w(f"{prefix}/www/audio/bgm/town.mid", b"MThd" + struct.pack(">IHHH", 6, 1, 1, 96) + b"MTrk" + struct.pack(">I", 4) + b"\x00\xff\x2f\x00")
    w(f"{prefix}/www/audio/se/hit.wav", b"RIFF" + struct.pack("<I", 36) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, 22050, 44100, 2, 16) + b"data" + struct.pack("<I", 0))
    w(f"{prefix}/www/movies/outro.mp4", mp4_bytes(moov_at_end=True))
    w(f"{prefix}/package.json", '{"name":"mv","main":"www/index.html","window":{"title":"MV","width":816,"height":624}}')
    w(f"{prefix}/Game.exe", PE)
    if encrypted:
        w(f"{prefix}/www/img/characters/Actor1.rpgmvp", b"RPGMV\0\0\0\0\0\x03\x01\0\0\0\0" + bytes(16) + PNG[16:])
    else:
        w(f"{prefix}/www/img/characters/Actor1.png", PNG)

def mz_tree(prefix):
    w(f"{prefix}/index.html", "<!DOCTYPE html><html><head><title>MZ</title></head><body><script src='js/main.js'></script></body></html>")
    w(f"{prefix}/js/rmmz_core.js", "//=============================================================================\n// rmmz_core.js v1.9.0\nUtils.RPGMAKER_NAME = \"MZ\";\nUtils.RPGMAKER_VERSION = \"1.9.0\";\n")
    w(f"{prefix}/js/libs/vorbisdecoder.js", "// vorbis decoder stub\n")
    w(f"{prefix}/js/plugins.js", "var $plugins =\n[\n];\n")
    w(f"{prefix}/data/System.json", system_json(False))
    w(f"{prefix}/movies/intro.webm", WEBM)
    w(f"{prefix}/audio/bgm/a.ogg", OGG)
    w(f"{prefix}/img/characters/Actor1.png", PNG)
    w(f"{prefix}/package.json", '{"name":"mz","main":"index.html"}')
    w(f"{prefix}/Game.exe", PE)

def rgss(prefix, ini_lib, archive, scripts, header_version):
    w(f"{prefix}/Game.ini", f"[Game]\r\nRTP=Standard\r\nLibrary={ini_lib}\r\nScripts=Data\\Scripts.{scripts.split('.')[-1]}\r\nTitle=Synthetic\r\n")
    w(f"{prefix}/Game.exe", PE)
    w(f"{prefix}/{archive}", b"RGSSAD\0" + bytes([header_version]) + b"\0" * 56)
    w(f"{prefix}/Data/{scripts}", b"\x04\x08[\x06[\x08i\x03" + b"# encoding: ruby 1.8 grammar sample: puts 'hi' if x and not y\n" + b"\0" * 32)

def renpy(prefix, libs, version_file, version_text, extra=()):
    for d in libs:
        w(f"{prefix}/{d}/.keep", b"")
    w(f"{prefix}/{version_file}", version_text)
    w(f"{prefix}/game/script.rpyc", b"RENPY RPC2" + b"\0" * 22 + b"\x78\x9c" + bytes(40))
    w(f"{prefix}/game/options.rpy", "define config.name = _(\"Synthetic\")\n")
    w(f"{prefix}/Synthetic.exe", PE)
    for rel, data in extra:
        w(f"{prefix}/{rel}", data)

def build():
    if os.path.isdir(ROOT):
        shutil.rmtree(ROOT)
    os.makedirs(ROOT)
    # ---- web engines ----
    mv_tree("mv-basic"); mv_tree("mv-encrypted", encrypted=True)
    mz_tree("mz-basic"); mz_tree("mz-nwplugin")
    w("mz-nwplugin/js/plugins.js", "var $plugins =\n[\n{\"name\":\"NwFs\",\"status\":true,\"description\":\"saves through node fs\",\"parameters\":{}}\n];\n")
    w("mz-nwplugin/js/plugins/NwFs.js", "/*:\n * @plugindesc writes saves with node fs\n */\nconst fs = require('fs');\nconst path = require('path');\n")
    w("html5-generic/index.html", "<!DOCTYPE html><html><head><title>Generic</title><script src='game.js'></script></head><body><canvas id='c'></canvas></body></html>")
    w("html5-generic/game.js", "const c=document.getElementById('c');\n")
    w("tyrano-min/index.html", "<!DOCTYPE html><html><head><script src='tyrano/tyrano.js'></script></head><body><div id='tyrano_base'></div></body></html>")
    w("tyrano-min/tyrano/tyrano.js", "var tyrano = {version: '5.20'};\n")
    w("tyrano-min/data/scenario/first.ks", "*start\n[cm]\nhello[l]\n")
    w("twine-min/index.html", "<!DOCTYPE html><html><body><tw-storydata name=\"Synthetic\" startnode=\"1\" creator=\"Twine\" creator-version=\"2.6.2\" format=\"SugarCube\" format-version=\"2.36.1\"><tw-passagedata pid=\"1\" name=\"Start\">Hello</tw-passagedata></tw-storydata></body></html>")
    w("unity-web-min/index.html", "<!DOCTYPE html><html><body><canvas id='unity-canvas'></canvas><script>createUnityInstance(document.querySelector('#unity-canvas'), {dataUrl: 'Build/x.data'});</script></body></html>")
    w("unity-web-min/Build/x.loader.js", "function createUnityInstance(){}\n")
    w("unity-web-min/Build/x.framework.js.br", b"\x1b\x00\x00\x00" + bytes(16))
    w("unity-web-min/Build/x.wasm", b"\0asm\x01\0\0\0")
    w("unity-web-min/Build/x.data", b"UnityWebData1.0\0" + bytes(32))
    w("godot-web-min/index.html", "<!DOCTYPE html><html><body><canvas id='canvas'></canvas><script src='index.js'></script><script>new Engine({executable:'index'}).startGame({mainPack:'index.pck'});</script></body></html>")
    w("godot-web-min/index.js", "var Engine = function(){};\n")
    w("godot-web-min/index.pck", gdpc(4, 7, 2))
    w("godot-web-min/index.wasm", b"\0asm\x01\0\0\0")
    # ---- RGSS ----
    rgss("rgss-xp", "RGSS104E.dll", "Game.rgssad", "Scripts.rxdata", 1)
    rgss("rgss-vx", "RGSS202E.dll", "Game.rgss2a", "Scripts.rvdata", 1)
    rgss("rgss-vxace", "RGSS301.dll", "Game.rgss3a", "Scripts.rvdata2", 3)
    w("rgss-essentials-like/Game.ini", "[Game]\r\nLibrary=RGSS301.dll\r\nScripts=Data\\Scripts.rvdata2\r\nTitle=Essentials\r\n")
    w("rgss-essentials-like/Game.exe", PE)
    w("rgss-essentials-like/x64-msvcrt-ruby310.dll", PE)
    w("rgss-essentials-like/mkxp.json", json.dumps({"rgssVersion": 3, "preloadScript": ["Scripts/"], "customScript": ""}, indent=2))
    w("rgss-essentials-like/Data/Scripts.rvdata2", b"\x04\x08[\x00")
    w("rgss-essentials-like/Data/Map001.rvdata2", b"\x04\x08o:\x0cRPG::Map\x00")
    # ---- Ren'Py ----
    renpy("renpy-7x", ["lib/py2-windows-x86_64", "lib/pythonlib2.7"], "renpy/__init__.py",
          "version_tuple = (7, 8, 7, 24020701)\nversion_name = \"Synthetic\"\n", [("game/script_version.txt", "(7, 8, 7)\n")])
    renpy("renpy-81", ["lib/py3-windows-x86_64", "lib/python3.9"], "renpy/vc_version.py", "version = \"8.1.3.23091805\"\nofficial = True\n")
    renpy("renpy-85", ["lib/py3-windows-x86_64", "lib/python3.12"], "renpy/vc_version.py", "version = \"8.5.3.26050201\"\nofficial = True\n",
          [("game/cache/bytecode-312.rpyb", b"\x80\x04\x95" + bytes(32))])
    # ---- RPG Maker 2000/2003 ----
    w("rm2k3-min/RPG_RT.ini", "[RPG_RT]\r\nGameTitle=Synthetic 2003\r\nMapEditMode=0\r\nFullPackageFlag=1\r\n")
    w("rm2k3-min/RPG_RT.ldb", b"\x0bLcfDataBase" + bytes(32))
    w("rm2k3-min/RPG_RT.lmt", b"\x0aLcfMapTree" + bytes(32))
    w("rm2k3-min/Map0001.lmu", b"\x0aLcfMapUnit" + bytes(16))
    w("rm2k3-min/RPG_RT.exe", PE)
    # ---- Godot ----
    w("godot-47-min/game.pck", gdpc(4, 7, 2)); w("godot-47-min/game.exe", PE)
    w("godot-3-min/game.pck", gdpc(3, 5, 3, fmt=1)); w("godot-3-min/game.exe", PE)
    w("godot-gdextension/game.pck", gdpc(4, 7, 2)); w("godot-gdextension/game.exe", PE)
    w("godot-gdextension/bin/native.gdextension", "[configuration]\nentry_symbol = \"native_init\"\n[libraries]\nwindows.x86_64 = \"res://bin/native.dll\"\n")
    w("godot-gdextension/bin/native.dll", PE)
    w("godot-encrypted/game.pck", gdpc(4, 7, 2, flags=1)); w("godot-encrypted/game.exe", PE)
    # ---- refusals ----
    ggm = bytearray(0x60); struct.pack_into(">IIII", ggm, 0, 0, 0x60, 22, 0)
    ggm[0x30:0x30 + 12] = b"2022.3.20f1\0"
    w("unity-native-il2cpp/Game.exe", PE); w("unity-native-il2cpp/UnityPlayer.dll", PE); w("unity-native-il2cpp/GameAssembly.dll", PE)
    w("unity-native-il2cpp/Game_Data/globalgamemanagers", bytes(ggm))
    w("unity-native-il2cpp/Game_Data/il2cpp_data/Metadata/global-metadata.dat", b"\xaf\x1b\xb1\xfa" + struct.pack("<I", 29) + bytes(24))
    w("unity-native-mono/Game.exe", PE); w("unity-native-mono/UnityPlayer.dll", PE)
    w("unity-native-mono/Game_Data/globalgamemanagers", bytes(ggm))
    w("unity-native-mono/Game_Data/Managed/Assembly-CSharp.dll", PE)
    w("unreal-min/Game.exe", PE)
    w("unreal-min/Game/Binaries/Win64/Game-Win64-Shipping.exe", PE)
    w("unreal-min/Game/Content/Paks/Game-WindowsNoEditor.pak", b"\0" * 32 + struct.pack("<I", 0x5A6F12E1))
    w("unreal-min/Engine/Binaries/ThirdParty/.keep", b"")
    w("gamemaker-min/Game.exe", PE)
    w("gamemaker-min/data.win", b"FORM" + struct.pack("<I", 64) + b"GEN8" + struct.pack("<I", 56) + bytes(56))
    w("wolf-min/Game.exe", PE)
    w("wolf-min/Data/Game.dat", b"\0W\0\0OL\0FM\0" + bytes(32))
    w("wolf-min/Data/BasicData/Game.wolf", b"\0" * 16)
    w("kirikiri-min/game.exe", PE)
    w("kirikiri-min/data.xp3", b"XP3\r\n \n\x1a\x8b\x67\x01" + bytes(32))
    for i in range(4):
        w(f"unknown-min/file{i}.bin", bytes(rnd.getrandbits(8) for _ in range(256)))
    w("unknown-min/readme.txt", "nothing to see\n")
    os.makedirs(os.path.join(ROOT, "empty"), exist_ok=True)
    # ---- archives ----
    mv_entries = []
    for dirpath, _, files in sorted(os.walk(os.path.join(ROOT, "mv-basic"))):
        for f in sorted(files):
            p = os.path.join(dirpath, f)
            mv_entries.append((os.path.relpath(p, ROOT).replace(os.sep, "/"), open(p, "rb").read()))
    zip_write(os.path.join(ROOT, "mv-basic.zip"), mv_entries)
    zip_write(os.path.join(ROOT, "mv-basic-nested.zip"), [("inner/mv-basic.zip", zip_bytes(mv_entries)), ("readme.txt", b"zip in zip\n")])
    zip_write(os.path.join(ROOT, "traversal.zip"), [("../../evil.txt", b"escaped\n"), ("ok.txt", b"fine\n")])
    zip_write(os.path.join(ROOT, "absolute.zip"), [("/etc/x", b"absolute\n"), ("ok.txt", b"fine\n")])
    with tarfile.open(os.path.join(ROOT, "symlink.tar"), "w", format=tarfile.USTAR_FORMAT) as tf:
        ti = tarfile.TarInfo("ok.txt"); ti.size = 5; ti.mtime = MTIME; ti.mode = 0o644
        tf.addfile(ti, io.BytesIO(b"fine\n"))
        ti = tarfile.TarInfo("link"); ti.type = tarfile.SYMTYPE; ti.linkname = "../../../etc/passwd"; ti.mtime = MTIME; ti.mode = 0o777
        tf.addfile(ti)
        ti = tarfile.TarInfo("link/inner.txt"); ti.size = 5; ti.mtime = MTIME; ti.mode = 0o644
        tf.addfile(ti, io.BytesIO(b"trap\n"))
    os.utime(os.path.join(ROOT, "symlink.tar"), (MTIME, MTIME))
    bomb = os.path.join(ROOT, "bomb-ratio.zip")
    with zipfile.ZipFile(bomb, "w") as zf:
        zi = zipfile.ZipInfo("zeros.bin", date_time=TS); zi.compress_type = zipfile.ZIP_DEFLATED; zi.external_attr = 0o644 << 16
        chunk = bytes(1 << 20)
        with zf.open(zi, "w", force_zip64=True) as f:
            for _ in range(2048):  # 2 GiB streamed, never held in memory
                f.write(chunk)
    os.utime(bomb, (MTIME, MTIME))
    full = zip_bytes(mv_entries)
    w("corrupt.zip", full[: len(full) // 2])
    sjis = [("ゲーム/データ/システム.json".encode("cp932").decode("cp437"), b"{}"), ("ゲーム/読んで.txt".encode("cp932").decode("cp437"), b"cp932\n")]
    zip_write(os.path.join(ROOT, "shiftjis-names.zip"), sjis, raw_names=True)
    nw = zip_bytes([("package.json", b'{"name":"mv","main":"www/index.html"}'), ("www/index.html", b"<html></html>"), ("www/js/rpg_core.js", b'Utils.RPGMAKER_VERSION = "1.6.2";')])
    w("nwjs-appended.exe", PE + nw)
    pck = gdpc(4, 7, 2)
    w("godot-embedded.exe", PE + pck + struct.pack("<Q", len(pck)) + b"GDPC")
    zip_write(os.path.join(ROOT, "renpy-apk-min.apk"), [("AndroidManifest.xml", b"\x03\x00\x08\x00" + bytes(16)), ("assets/x-game/x-script.rpyc", b"RENPY RPC2" + bytes(32)),
                                                       ("assets/private.mp3", zip_bytes([("lib/python3.9/.keep", b""), ("renpy/vc_version.py", b'version = "8.1.3"\n')])), ("classes.dex", b"dex\n035\0" + bytes(16))], compression=zipfile.ZIP_STORED)
    zip_write(os.path.join(ROOT, "mv.jgp"), [("manifest.json", json.dumps({"name": "Synthetic MV", "engine": "rpgmv", "version": 1}, sort_keys=True).encode()),
                                          ("configuration.json", b'{"screen":"landscape"}'), ("gamepad.json", b'{"layout":"default"}'), ("www/index.html", b"<html></html>")])
    manifest()

def manifest():
    lines = []
    for dirpath, dirs, files in os.walk(ROOT):
        dirs.sort()
        for f in sorted(files):
            if f == "MANIFEST.sha256":
                continue
            p = os.path.join(dirpath, f)
            rel = os.path.relpath(p, ROOT).replace(os.sep, "/")
            lines.append(f"{hashlib.sha256(open(p, 'rb').read()).hexdigest()}  {rel}")
    with open(os.path.join(ROOT, "MANIFEST.sha256"), "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"{len(lines)} fixture files under {ROOT}")

if __name__ == "__main__":
    build()
