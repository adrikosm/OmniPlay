#!/bin/zsh
# Verifies the pinned toolchain and installs missing Homebrew tools. Idempotent: a second run reports
# "nothing to do". Exit 1 = wrong or missing Xcode/Swift, exit 2 = Homebrew failure.
set -uo pipefail
cd "$(dirname "$0")/.."
want="$(cat .xcode-version)"

have="$(xcodebuild -version 2>/dev/null | awk 'NR==1{print $2}')"
if [[ -z "$have" ]]; then
  echo "Xcode $want is required but xcodebuild is not available. Install Xcode $want from developer.apple.com, then: sudo xcode-select -s /Applications/Xcode.app" >&2; exit 1
fi
if [[ "${have%%.*}" != "${want%%.*}" ]]; then
  echo "Xcode $have found, $want required (.xcode-version). Install Xcode $want and run: sudo xcode-select -s /Applications/Xcode.app" >&2; exit 1
fi
if [[ "$(xcode-select -p)" != /Applications/Xcode.app/* ]]; then
  echo "xcode-select points at $(xcode-select -p). Run: sudo xcode-select -s /Applications/Xcode.app" >&2; exit 1
fi
swiftv="$(swift --version 2>&1 | grep -oE 'Swift version [0-9]+\.[0-9]+' | awk '{print $3}')"
if [[ "$swiftv" != 6.4 ]]; then
  echo "Swift 6.4 required, found ${swiftv:-none}. It ships with Xcode $want; check xcode-select." >&2; exit 1
fi
if ! command -v brew >/dev/null; then
  echo "Homebrew is required for xcodegen, ninja, meson, scons and pkg-config: https://brew.sh" >&2; exit 2
fi

if brew bundle check --file=Brewfile >/dev/null 2>&1; then
  brew_state="nothing to do"
else
  brew bundle install --file=Brewfile --no-upgrade || { echo "brew bundle failed; see the formula named above" >&2; exit 2; }
  brew_state="installed missing formulae"
fi
Scripts/install-hooks.sh

printf '\n%-12s %s\n' tool version
printf '%-12s %s\n' xcode "$have" swift "$swiftv"
for t in xcodegen ninja meson scons pkg-config swiftlint swiftformat; do
  printf '%-12s %s\n' "$t" "$($t --version 2>&1 | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"
done
printf '%-12s %s\n' minisign "$(minisign -v 2>&1 | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"
echo "\nbrew: $brew_state"
