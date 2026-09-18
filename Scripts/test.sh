#!/bin/zsh
# swift test for every local package on the Mac host, then the app test bundle on the simulator.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
for p in Packages/*/; do
  echo "==> ${p%/}"
  (cd "$p" && swift test 2>&1 | grep -E 'passed after|failed|error:' | tail -3) || fail=1
  [[ ${pipestatus[1]:-0} -ne 0 ]] && fail=1
done
Scripts/generate-project.sh >/dev/null
echo "==> OmniPlayTests (simulator)"
xcodebuild -project OmniPlay.xcodeproj -scheme OmniPlay -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=27.0' \
  -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO test 2>&1 | grep -E 'Executed|TEST (SUCCEEDED|FAILED)|error:' | tail -5
[[ ${pipestatus[1]} -ne 0 ]] && fail=1
(( fail )) && { echo "test.sh: FAILED"; exit 1; }
echo "test.sh: all green"
