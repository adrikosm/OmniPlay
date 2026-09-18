#!/bin/zsh
# build-renpy-engines.sh — Ren'Py 8.5.3 / 8.3.7 / 7.8.7 from renpy-build with main.c replaced, MetalANGLE (§7)
# Phase: Phase 3 (design authority docs/planning/MASTER-ARCHITECTURE-CHOICES.md §19–§20)
#
# Contract when implemented:
#   - inputs:  pinned sources under Engines/third_party/, toolchain from .xcode-version
#   - outputs: Engines/artifacts/<Artefact>.{framework,xcframework} + Engines/manifests/<Artefact>.json
#   - device (arm64) first; simulator slice only where the engine supports it
#   - never touches the network (only fetch-native-deps.sh may)
set -euo pipefail
cd "$(dirname "$0")/../.."
echo "build-renpy-engines.sh: not implemented yet — scheduled for Phase 3." >&2
exit 2
