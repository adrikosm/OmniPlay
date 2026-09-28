#!/bin/zsh
# Pre-commit guard for a public, code-only repository. Reads the staged paths and refuses the commit
# when any of them is documentation (other than README.md), an AI-assistant file, signing config,
# a private or large fixture, an oversized file, a native binary, or text carrying a private key or
# a real DEVELOPMENT_TEAM, or this Mac's home path. Agents never bypass it with --no-verify.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
limit=$((5 << 20))
manifest=Fixtures/synthetic/MANIFEST.sha256
bad=()
ai='^(\.claude/|CLAUDE\.md$|CLAUDE\.local\.md$|AGENTS\.md$|GEMINI\.md$|\.cursor/|\.cursorrules$|\.cursorignore$|\.windsurf/|\.windsurfrules$|\.continue/|\.aider|\.codex/|\.mcp\.json$|mcp\.json$|\.skills/|.*\.skill$|\.github/copilot-instructions\.md$|\.github/instructions/|\.roo/|\.clinerules$|\.gemini/|\.copilot/|.*\.agent\.md$|\.claude\.json$|\.agents/|\.kiro/|\.junie/|\.augment/|\.opencode/|opencode\.json$|\.qwen/|\.coderabbit\.ya?ml$|llms\.txt$|memory/|scratchpad/|tmp/)'

git diff --cached --name-only --diff-filter=ACMR -z | while IFS= read -r -d '' f; do
  case "$f" in
    README.md) ;;
    *.md|*.markdown|*.mdx) bad+=("$f  (documentation: only README.md may be committed)") ;;
  esac
  [[ "$f" =~ $ai ]] && bad+=("$f  (AI-assistant file)")
  case "$f" in
    Signing.xcconfig|*.mobileprovision|*.provisionprofile|*.p12|*.cer|.env|.env.*|*.pem|*.key|.netrc) bad+=("$f  (signing / secret)") ;;
    *.local|*.local.*) bad+=("$f  (per-machine config)") ;;
    Scratch*.swift|*/Scratch*.swift) bad+=("$f  (scratch test driver)") ;;
    Fixtures/private/README.txt|Fixtures/private/.gitkeep|Fixtures/large/.gitkeep) ;;
    Fixtures/private/*|Fixtures/large/*) bad+=("$f  (private or large fixture)") ;;
    *.a|*.o|*.d|*.dylib) bad+=("$f  (native binary)") ;;
  esac
  size=$(git cat-file -s ":$f" 2>/dev/null || echo 0)
  if (( size > limit )); then
    if [[ "$f" == Fixtures/synthetic/* ]] && [[ -f $manifest ]] && grep -q -- " ${f#Fixtures/synthetic/}\$" "$manifest"; then :; else
      bad+=("$f  ($((size >> 20)) MiB > 5 MiB)")
    fi
  fi
  magic=$(git show ":$f" 2>/dev/null | head -c 4 | xxd -p)
  case "$magic" in cffaedfe|cefaedfe|feedface|feedfacf|cafebabe) bad+=("$f  (Mach-O binary)") ;; esac
  if git show ":$f" 2>/dev/null | grep -qa -- 'BEGIN [A-Z ]*PRIVATE KEY'; then bad+=("$f  (private key material)"); fi
  if git show ":$f" 2>/dev/null | grep -Eaq 'DEVELOPMENT_TEAM *= *[A-Z0-9]{10}([^A-Z0-9_]|$)'; then bad+=("$f  (real DEVELOPMENT_TEAM value)"); fi
  if git show ":$f" 2>/dev/null | grep -qaF -- "$HOME/"; then bad+=("$f  (contains this Mac's home path)"); fi
done

if (( ${#bad} )); then
  echo "check-public-safe: refusing to commit" >&2
  printf '  %s\n' "${bad[@]}" >&2
  exit 1
fi
