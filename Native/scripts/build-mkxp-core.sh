#!/bin/zsh
# build-mkxp-core.sh — libmkxpz-core + CRuby 1.8/1.9/3.1 + shared SDL2 + ANGLE as embedded frameworks (§6)
# Phase: Phase 2 (design authority docs/planning/MASTER-ARCHITECTURE-CHOICES.md §19–§20)
#
# Contract when implemented:
#   - inputs:  pinned sources under Engines/third_party/, toolchain from .xcode-version
#   - outputs: Engines/artifacts/<Artefact>.{framework,xcframework} + Engines/manifests/<Artefact>.json
#   - device (arm64) first; simulator slice only where the engine supports it
#   - never touches the network (only fetch-native-deps.sh may)
set -euo pipefail
cd "$(dirname "$0")/../.."
echo "build-mkxp-core.sh: not implemented yet — scheduled for Phase 2." >&2
exit 2
