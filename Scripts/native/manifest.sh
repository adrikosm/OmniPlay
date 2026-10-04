#!/bin/zsh
# manifest.sh <component> <artefact dir> <submodule path>...
# Writes Native/manifests/<component>.json: what was built, from which commits, with which toolchain, and the
# sha256 of every file under the artefact directory.
source "$(dirname "$0")/common.sh"
cd "$NATIVE_ROOT"
component="$1"; artefact="$2"; shift 2
[[ -d "$artefact" ]] || { echo "artefact directory missing: $artefact" >&2; exit 1; }
out="Native/manifests/$component.json"
mkdir -p Native/manifests
python3 - "$component" "$artefact" "$out" "$IOS_MIN" "$MACOS_MIN" "$@" <<'PY'
import hashlib, json, os, subprocess, sys, datetime
def _sha256(fh):  # hashlib.file_digest needs Python 3.11; Xcode's python3 is 3.9
    h = hashlib.sha256()
    for chunk in iter(lambda: fh.read(1 << 20), b""):
        h.update(chunk)
    return h
component, artefact, out, ios_min, macos_min, *subs = sys.argv[1:]
def run(*a): return subprocess.check_output(a, text=True).strip()
outputs = {}
for dirpath, _, files in os.walk(artefact):
    for f in sorted(files):
        p = os.path.join(dirpath, f)
        with open(p, "rb") as fh:
            outputs[os.path.relpath(p, artefact)] = _sha256(fh).hexdigest()
manifest = {
    "component": component,
    "artefact": artefact,
    "built_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "toolchain": run("xcodebuild", "-version").replace("\n", " "),
    "sdks": {s: run("xcrun", "--sdk", s, "--show-sdk-version") for s in ("iphoneos", "iphonesimulator", "macosx")},
    "arch": "arm64",
    "flags": {"iphoneos_min": ios_min, "macosx_min": macos_min},
    "sources": {s: run("git", "-C", s, "rev-parse", "HEAD") for s in subs},
    "outputs": dict(sorted(outputs.items())),
}
with open(out, "w") as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
    f.write("\n")
print(f"wrote {out} ({len(outputs)} outputs)")
PY
