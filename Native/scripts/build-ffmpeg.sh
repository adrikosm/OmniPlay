#!/bin/zsh
# build-ffmpeg.sh — FFmpeg 9, LGPL configuration, iOS arm64 — WebM→MP4, Theora, MIDI soundfont paths (§12.5)
# Phase: Phase 1 (design authority docs/planning/MASTER-ARCHITECTURE-CHOICES.md §19–§20)
#
# Contract when implemented:
#   - inputs:  pinned sources under Engines/third_party/, toolchain from .xcode-version
#   - outputs: Engines/artifacts/<Artefact>.{framework,xcframework} + Engines/manifests/<Artefact>.json
#   - device (arm64) first; simulator slice only where the engine supports it
#   - never touches the network (only fetch-native-deps.sh may)
set -euo pipefail
cd "$(dirname "$0")/../.."
echo "build-ffmpeg.sh: not implemented yet — scheduled for Phase 1." >&2
exit 2
