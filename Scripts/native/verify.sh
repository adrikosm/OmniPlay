#!/bin/zsh
# verify.sh [component]  Recomputes the sha256 of every output named in the manifest(s); exit 1 on any missing
# or changed file, exit 2 when a manifest is absent. Prints one line per component.
source "$(dirname "$0")/common.sh"
cd "$NATIVE_ROOT"
rc=0
for manifest in Native/manifests/${1:-*}.json; do
  [[ -f "$manifest" ]] || { echo "verify: no manifest for ${1:-any component}" >&2; exit 2; }
  python3 - "$manifest" <<'PY' || rc=1
import hashlib, json, os, sys
m = json.load(open(sys.argv[1]))
bad = []
for rel, want in m["outputs"].items():
    p = os.path.join(m["artefact"], rel)
    if not os.path.exists(p):
        bad.append(f"missing {rel}"); continue
    h = hashlib.sha256()
    with open(p, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    if h.hexdigest() != want:
        bad.append(f"changed {rel}")
if bad:
    print(f"verify {m['component']}: FAILED " + "; ".join(bad[:5]))
    sys.exit(1)
print(f"verify {m['component']}: OK ({len(m['outputs'])} outputs, built {m['built_at']})")
PY
done
exit $rc
