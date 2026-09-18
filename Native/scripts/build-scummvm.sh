#!/bin/zsh
# build-scummvm.sh — ScummVM static library, headless-driven, AGS/Wintermute/Director/Glk enabled (§11.1)
# Phase: Phase 4 (design authority docs/planning/MASTER-ARCHITECTURE-CHOICES.md §19–§20)
#
# Contract when implemented:
#   - inputs:  pinned sources under Engines/third_party/, toolchain from .xcode-version
#   - outputs: Engines/artifacts/<Artefact>.{framework,xcframework} + Engines/manifests/<Artefact>.json
#   - device (arm64) first; simulator slice only where the engine supports it
#   - never touches the network (only fetch-native-deps.sh may)
set -euo pipefail
cd "$(dirname "$0")/../.."
echo "build-scummvm.sh: not implemented yet — scheduled for Phase 4." >&2
exit 2
