#!/bin/zsh
# Proves the ignore rules keep documentation, AI-assistant files, signing config, private fixtures
# and native artefacts out of the public repository. Never touches the working tree: check-ignore
# matches paths that need not exist, and the guard runs against blobs in a throwaway index.
set -uo pipefail
cd "$(dirname "$0")/.."
decoys=(
  CLAUDE.md .claude/x Signing.xcconfig docs/x.md Fixtures/private/x.bin Fixtures/large/x.bin
  App/Notes.md Native/x/prebuilt/lib.a Native/x/y.d .cursor/rules AGENTS.md .mcp.json
  OmniPlay.xcodeproj/project.pbxproj Logs/host.log memory/x.md Tests/OmniPlayUITests/ScratchDriver.swift
)
fail=0
for f in $decoys; do
  if git check-ignore -q --no-index "$f"; then echo "  ignored   $f"; else echo "  LEAKS     $f"; fail=1; fi
done
for f in README.md App/X.swift Scripts/x.sh Fixtures/synthetic/x.zip Signing.xcconfig.example Fixtures/private/README.txt; do
  if git check-ignore -q --no-index "$f"; then echo "  BLOCKED   $f (should be committable)"; fail=1; else echo "  tracked   $f"; fi
done

# Stages stdin as $1 in the throwaway index without writing a file.
stage() { git update-index --add --cacheinfo "100644,$(git hash-object -w --stdin),$1"; }

if [[ -x Scripts/check-public-safe.sh ]]; then
  echo "guard against a throwaway index:"
  export GIT_INDEX_FILE="$(mktemp)"; /bin/rm -f "$GIT_INDEX_FILE"
  for f in docs/x.md CLAUDE.md .claude/settings.json Signing.xcconfig Fixtures/private/x.bin big.bin lib.a home.txt; do
    case $f in
      big.bin) head -c $((6 << 20)) /dev/zero | stage "$f" ;;
      lib.a) printf '!<arch>\n' | stage "$f" ;;
      home.txt) print -r -- "$HOME/x" | stage "$f" ;;
      *) : | stage "$f" ;;
    esac
    if Scripts/check-public-safe.sh >/dev/null 2>&1; then echo "  PASSED    $f (guard should reject)"; fail=1; else echo "  rejected  $f"; fi
    git update-index --force-remove "$f"
  done
  : | stage App/X.swift
  if Scripts/check-public-safe.sh >/dev/null 2>&1; then echo "  accepted  App/X.swift"; else echo "  REJECTED  App/X.swift (guard should pass)"; fail=1; fi
  /bin/rm -f "$GIT_INDEX_FILE"; unset GIT_INDEX_FILE
fi
(( fail )) && { echo "verify-gitignore: FAILED"; exit 1; }
echo "verify-gitignore: OK"
