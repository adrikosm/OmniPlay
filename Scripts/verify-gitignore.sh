#!/bin/zsh
# Proves the ignore rules keep documentation, AI-assistant files, signing config, private fixtures
# and native artefacts out of the public repository. Creates decoys, checks them, removes them.
set -uo pipefail
cd "$(dirname "$0")/.."
decoys=(
  CLAUDE.md .claude/x Signing.xcconfig docs/x.md Fixtures/private/x.bin Fixtures/large/x.bin
  App/Notes.md Native/x/prebuilt/lib.a .cursor/rules AGENTS.md .mcp.json OmniPlay.xcodeproj/project.pbxproj
  Logs/host.log memory/x.md
)
fail=0
for f in $decoys; do
  mkdir -p "$(dirname "$f")"; : > "$f"
  if git check-ignore -q "$f"; then echo "  ignored   $f"; else echo "  LEAKS     $f"; fail=1; fi
done
for f in README.md App/X.swift Scripts/x.sh Fixtures/synthetic/x.zip Signing.xcconfig.example Fixtures/private/README.txt; do
  if git check-ignore -q "$f"; then echo "  BLOCKED   $f (should be committable)"; fail=1; else echo "  tracked   $f"; fi
done
for f in $decoys; do /bin/rm -f "$f"; done
for d in .claude docs .cursor Native/x/prebuilt Native/x OmniPlay.xcodeproj Logs memory; do rmdir "$d" 2>/dev/null || true; done

if [[ -x Scripts/check-public-safe.sh ]]; then
  echo "guard against a throwaway index:"
  export GIT_INDEX_FILE="$(mktemp)"; /bin/rm -f "$GIT_INDEX_FILE"
  for f in docs/x.md CLAUDE.md .claude/settings.json Signing.xcconfig Fixtures/private/x.bin big.bin lib.a; do
    mkdir -p "$(dirname "$f")"
    case $f in big.bin) head -c $((6 << 20)) /dev/zero > "$f" ;; lib.a) printf '!<arch>\n' > "$f" ;; *) : > "$f" ;; esac
    git add -f "$f"
    if Scripts/check-public-safe.sh >/dev/null 2>&1; then echo "  PASSED    $f (guard should reject)"; fail=1; else echo "  rejected  $f"; fi
    git rm -q --cached "$f"; /bin/rm -f "$f"
  done
  : > App/X.swift; git add -f App/X.swift
  if Scripts/check-public-safe.sh >/dev/null 2>&1; then echo "  accepted  App/X.swift"; else echo "  REJECTED  App/X.swift (guard should pass)"; fail=1; fi
  git rm -q --cached App/X.swift; /bin/rm -f App/X.swift
  /bin/rm -f "$GIT_INDEX_FILE"; unset GIT_INDEX_FILE
  for d in .claude docs Fixtures/private; do rmdir "$d" 2>/dev/null || true; done
fi
(( fail )) && { echo "verify-gitignore: FAILED"; exit 1; }
echo "verify-gitignore: OK"
