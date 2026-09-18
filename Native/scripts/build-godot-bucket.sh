#!/bin/zsh
# build-godot-bucket.sh — libgodot bucket A (4.7.x) / bucket B (4.4.x) from a hand-rebased fork (§9)
# Phase: Phase 6 (design authority docs/planning/MASTER-ARCHITECTURE-CHOICES.md §19–§20)
#
# Contract when implemented:
#   - inputs:  pinned sources under Engines/third_party/, toolchain from .xcode-version
#   - outputs: Engines/artifacts/<Artefact>.{framework,xcframework} + Engines/manifests/<Artefact>.json
#   - device (arm64) first; simulator slice only where the engine supports it
#   - never touches the network (only fetch-native-deps.sh may)
set -euo pipefail
cd "$(dirname "$0")/../.."
echo "build-godot-bucket.sh: not implemented yet — scheduled for Phase 6." >&2
exit 2
