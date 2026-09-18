#!/bin/zsh
# fetch-native-deps.sh — add or update pinned upstream sources in Engines/third_party (the only network-touching script)
# Phase: Phase 0/1 (design authority MASTER-ARCHITECTURE-CHOICES.md (kept outside the repo) §19–§20)
#
# Contract when implemented:
#   - inputs:  pinned sources under Engines/third_party/, toolchain from .xcode-version
#   - outputs: Engines/artifacts/<Artefact>.{framework,xcframework} + Engines/manifests/<Artefact>.json
#   - device (arm64) first; simulator slice only where the engine supports it
#   - never touches the network (only fetch-native-deps.sh may)
set -euo pipefail
cd "$(dirname "$0")/../.."
echo "fetch-native-deps.sh: not implemented yet — scheduled for Phase 0/1." >&2
exit 2
