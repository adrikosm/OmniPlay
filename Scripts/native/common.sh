#!/bin/zsh
# Shared settings for every native build: arm64 only, pinned deployment targets, SDK roots from the selected Xcode.
# Source this file; it sets variables and defines helpers, nothing else.
set -euo pipefail
NATIVE_ROOT="$(cd "$(dirname "${(%):-%x}")/../.." && pwd)"
IOS_MIN=27.0
MACOS_MIN=15.0
ARCH=arm64
sdk_path() { xcrun --sdk "$1" --show-sdk-path; }
sdk_version() { xcrun --sdk "$1" --show-sdk-version; }
require_tools() { for tool in "$@"; do command -v "$tool" >/dev/null || { echo "$tool missing: run Scripts/bootstrap-mac.sh" >&2; exit 1; }; done; }
# No pipe: under pipefail, head closing early can kill xcodebuild with SIGPIPE and fail the check on Xcode 27 itself.
require_xcode() { [[ "$(xcodebuild -version)" == "Xcode 27"* ]] || { echo "Xcode 27 required (xcode-select -s)" >&2; exit 1; }; }
# apply_patches <submodule> <patch dir>: OmniPlay's fixes to a pinned submodule. Each applies once: a patch already in
# the tree reverses cleanly and is skipped.
apply_patches() {
  local patch
  for patch in "$2"/*.patch(N); do
    git -C "$1" apply --reverse --check "$patch" 2>/dev/null && continue
    git -C "$1" apply "$patch" || { echo "cannot apply ${patch:t} to $1" >&2; exit 1; }
  done
}
# relink_without_spaces <script name> "$@": configure scripts and Makefiles that cannot take a path with spaces get the
# build re-run through a space-free symlink to the repository. `pwd` keeps the logical path, so derived paths stay
# clean. Returns when the path has no space or the script already runs through the link.
relink_without_spaces() {
  [[ "$NATIVE_ROOT" == *" "* && -z "${OMNIPLAY_NATIVE_LINKED:-}" ]] || return 0
  local link="$HOME/.omniplay-native" script=$1
  shift
  [[ -L "$link" && "$(readlink "$link")" == "$NATIVE_ROOT" ]] || { /bin/rm -f "$link"; ln -s "$NATIVE_ROOT" "$link"; }
  OMNIPLAY_NATIVE_LINKED=1 exec zsh "$link/Scripts/native/$script" "$@"
}
# fetch_pinned <file> <sha256> <url>: a pinned download, cached at <file>. No network when the cached file matches;
# a file that does not match after the download stops the build.
fetch_pinned() {
  if [[ ! -f "$1" ]] || [[ "$(shasum -a 256 "$1" | cut -d' ' -f1)" != "$2" ]]; then
    echo "==> downloading ${1:t}"
    mkdir -p "${1:h}"
    curl -fL --retry 3 -o "$1.part" "$3"
    /bin/mv "$1.part" "$1"
  fi
  [[ "$(shasum -a 256 "$1" | cut -d' ' -f1)" == "$2" ]] || { echo "${1:t}: sha256 mismatch" >&2; exit 1; }
}
