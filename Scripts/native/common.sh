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
require_xcode() { xcodebuild -version | head -1 | grep -q "Xcode 27" || { echo "Xcode 27 required (xcode-select -s)" >&2; exit 1; }; }
