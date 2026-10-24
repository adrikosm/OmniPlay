#!/bin/zsh
# The three tests, each guarding what cannot be regenerated or trusted: untrusted archives (GameImport), saves
# (SaveKit) and the library database (GameStore). Mac-only `swift test`, no simulator.
#   Scripts/test.sh        only the packages the uncommitted change touches (GameCore touches all three)
#   Scripts/test.sh --all  all three
# A new feature is checked once on the simulator, not with a new test here.
set -uo pipefail
cd "$(dirname "$0")/.."
changed=$(git status --porcelain -- Packages | awk '{print $NF}')
fail=0 ran=0
for t in Packages/*/Tests(/N); do
  p=${t:h}
  if [[ ${1:-} != --all ]] && ! print -r -- "$changed" | grep -qE "^($p|Packages/GameCore)/"; then
    continue
  fi
  echo "==> $p"
  # pipefail: a failing `swift test` fails the subshell even though tail succeeds.
  (cd "$p" && swift test 2>&1 | grep -E 'passed after|failed|error:' | tail -3) || fail=1
  ran=1
done
(( ran )) || echo "test.sh: no tested package changed (use --all to run them anyway)"
(( fail )) && { echo "test.sh: FAILED"; exit 1; }
echo "test.sh: green"
