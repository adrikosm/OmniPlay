#!/usr/bin/env python3
"""Deterministic huge installations for infrastructure tests. Nothing here resembles a real game; it proves
OmniPlay can index, copy, hash and serve a multi-GB tree, not that any 30 GB engine is compatible.

usage: make-large-fixture.py --size 32G --mode loose|zip|mv-like [--real 0.02] [--small] [--out DIR]

`loose` / `mv-like`: an MV-shaped tree (www/img/..., www/audio/..., www/data/...) with sizes drawn from a
seeded distribution. Bodies are APFS sparse files (ftruncate) so stat reports the full size while generation
stays fast; `--real` picks the fraction of files whose bytes are actually written (1 MiB PRNG blocks) so hashing
and copying have real work. `mv-like` adds the MV markers (rpg_core.js, System.json, index.html, package.json).
`zip`: the same tree stored (uncompressed) through a streaming ZipFile so extraction is I/O-bound.
`--small` caps everything at 64 MiB / 400 files for CI. Output lives under Fixtures/large/ (gitignored).
"""
import argparse, json, os, random, shutil, struct, sys, time, zipfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Fixtures", "large")

def parse_size(text):
    units = {"K": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40}
    text = text.strip().upper()
    return int(float(text[:-1]) * units[text[-1]]) if text[-1] in units else int(text)

def plan(total, files, rng):
    """(relative path, size) pairs summing to about `total`, MV-shaped."""
    folders = [("www/img/pictures", "png", 0.35), ("www/img/tilesets", "png", 0.1), ("www/img/characters", "png", 0.05),
               ("www/audio/bgm", "ogg", 0.2), ("www/audio/se", "ogg", 0.05), ("www/movies", "webm", 0.2), ("www/data", "json", 0.05)]
    entries = []
    for folder, ext, share in folders:
        count = max(1, int(files * share))
        budget = int(total * share)
        weights = [rng.lognormvariate(0, 1.2) for _ in range(count)]
        scale = budget / sum(weights)
        for i, w in enumerate(weights):
            entries.append((f"{folder}/{folder.split('/')[-1]}_{i:06d}.{ext}", max(1, int(w * scale))))
    return entries

def prng_blocks(seed, size):
    rng = random.Random(seed)
    remaining = size
    while remaining > 0:
        n = min(1 << 20, remaining)
        yield rng.randbytes(n)
        remaining -= n

def write_loose(out, entries, real, rng, mv_like):
    real_bytes = 0
    for i, (rel, size) in enumerate(entries):
        path = os.path.join(out, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            if rng.random() < real:
                for block in prng_blocks(i, size):
                    f.write(block)
                real_bytes += size
            else:
                f.truncate(size)
    if mv_like:
        markers = {
            "www/index.html": "<!DOCTYPE html><html><head><title>Large</title></head><body><script src='js/rpg_core.js'></script></body></html>",
            "www/js/rpg_core.js": "//=============================================================================\n// rpg_core.js v1.6.2\nUtils.RPGMAKER_NAME = \"MV\";\nUtils.RPGMAKER_VERSION = \"1.6.2\";\n",
            "www/js/plugins.js": "var $plugins =\n[\n];\n",
            "www/data/System.json": json.dumps({"gameTitle": "Large Synthetic", "hasEncryptedImages": False, "hasEncryptedAudio": False, "encryptionKey": ""}),
            "package.json": json.dumps({"name": "large", "main": "www/index.html"}),
        }
        for rel, text in markers.items():
            path = os.path.join(out, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(text)
    return real_bytes

def write_zip(out, entries, real, rng):
    real_bytes = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED, allowZip64=True) as zf:
        for i, (rel, size) in enumerate(entries):
            info = zipfile.ZipInfo(rel, date_time=(2024, 1, 1, 0, 0, 0))
            info.file_size = size
            if rng.random() < real:
                with zf.open(info, "w", force_zip64=True) as w:
                    for block in prng_blocks(i, size):
                        w.write(block)
                real_bytes += size
            else:
                zero = bytes(1 << 20)
                with zf.open(info, "w", force_zip64=True) as w:
                    remaining = size
                    while remaining > 0:
                        n = min(len(zero), remaining)
                        w.write(zero[:n])
                        remaining -= n
    return real_bytes

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--size", default="32G"); ap.add_argument("--mode", choices=["loose", "zip", "mv-like"], default="loose")
    ap.add_argument("--files", type=int, default=100_000); ap.add_argument("--real", type=float, default=0.02)
    ap.add_argument("--small", action="store_true"); ap.add_argument("--out", default=None); ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()
    total, files = parse_size(a.size), a.files
    if a.small:
        total, files = min(total, 64 << 20), min(files, 400)
    rng = random.Random(a.seed)
    entries = plan(total, files, rng)
    name = a.out or os.path.join(ROOT, f"{a.mode}-{a.size.lower()}{'-small' if a.small else ''}")
    need = int(total * a.real * 1.1) + (total if a.mode == "zip" else 0)
    free = shutil.disk_usage(os.path.dirname(os.path.abspath(name)) if os.path.exists(os.path.dirname(os.path.abspath(name))) else ROOT if os.path.exists(ROOT) else ".").free
    if free < need:
        sys.exit(f"need about {need >> 20} MiB free for real data, have {free >> 20} MiB")
    os.makedirs(ROOT, exist_ok=True)
    start = time.time()
    if a.mode == "zip":
        target = name if name.endswith(".zip") else name + ".zip"
        if os.path.exists(target):
            os.remove(target)
        real_bytes = write_zip(target, entries, a.real, rng)
    else:
        target = name
        if os.path.exists(target):
            shutil.rmtree(target)
        real_bytes = write_loose(target, entries, a.real, rng, a.mode == "mv-like")
    manifest = {"mode": a.mode, "files": len(entries), "declared_bytes": sum(s for _, s in entries), "real_bytes": real_bytes,
                "seed": a.seed, "small": a.small, "seconds": round(time.time() - start, 1)}
    with open(target + ".manifest.json" if a.mode == "zip" else os.path.join(target, "fixture.manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    print(json.dumps(manifest))

if __name__ == "__main__":
    main()
