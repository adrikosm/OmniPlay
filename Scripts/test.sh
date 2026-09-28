#!/bin/zsh
# swift test for every local package that still has tests, then the app test bundle on the simulator.
# The suite is deliberately tiny — see the testing policy before adding to it.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
for t in Packages/*/Tests(/N); do
  p=${t:h}
  echo "==> $p"
  (cd "$p" && swift test 2>&1 | grep -E 'passed after|failed|error:' | tail -3) || fail=1
  [[ ${pipestatus[1]:-0} -ne 0 ]] && fail=1
done
Scripts/generate-project.sh >/dev/null || exit 1
echo "==> OmniPlayTests (simulator)"
xcodebuild -project OmniPlay.xcodeproj -scheme OmniPlay \
  -destination "${OMNIPLAY_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro Max,OS=27.0}" \
  -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO test 2>&1 | grep -E 'Executed|TEST (SUCCEEDED|FAILED)|error:' | tail -5
[[ ${pipestatus[1]} -ne 0 ]] && fail=1
(( fail )) && { echo "test.sh: FAILED"; exit 1; }
echo "test.sh: all green"
