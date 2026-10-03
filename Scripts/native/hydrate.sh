#!/bin/zsh
# hydrate.sh [component]  Makes native artefacts present and valid before a build. Order: already valid → done;
# a verified copy in $OMNIPLAY_NATIVE_CACHE/<component>/ → restore; otherwise run the component's build script.
# Fails loudly with the bootstrap instruction when a tool is missing. Quiet and fast when nothing is needed: a component
# verified since its manifest last changed is only checked for presence (preflight's verify.sh still hashes everything).
source "$(dirname "$0")/common.sh"
cd "$NATIVE_ROOT"
typeset -A builders artefacts
builders=(unrar Scripts/build-unrar.sh libarchive Scripts/build-libarchive.sh mkxp-z Scripts/native/build-mkxpz.sh rgss-assets Scripts/native/assemble-rgss-assets.sh
          metalangle "Scripts/native/build-renpy.sh metalangle" renpy853 "Scripts/native/build-renpy.sh 8.5.3"
          renpy837 "Scripts/native/build-renpy.sh 8.3.7" renpy787 "Scripts/native/build-renpy.sh 7.8.7" easyrpg Scripts/native/build-easyrpg.sh
          libmspack Scripts/build-libmspack.sh fluidsynth Scripts/native/build-fluidsynth.sh soundfont Scripts/native/build-fluidsynth.sh
          ffmpeg Scripts/native/build-ffmpeg.sh scummvm Scripts/native/build-scummvm.sh godot Scripts/native/build-godot.sh
          godot3 Scripts/native/build-godot3.sh kirikiri Scripts/native/build-kirikiri.sh)
artefacts=(unrar Packages/GameImport/Native/unrar.xcframework libarchive Packages/GameImport/Native/libarchive.xcframework mkxp-z Native/prebuilt/mkxp-z rgss-assets Native/prebuilt/rgss-assets
           metalangle Native/prebuilt/renpy/metalangle renpy853 Native/prebuilt/renpy/8.5.3
           renpy837 Native/prebuilt/renpy/8.3.7 renpy787 Native/prebuilt/renpy/7.8.7 easyrpg Native/prebuilt/easyrpg
           libmspack Packages/GameImport/Native/libmspack.xcframework fluidsynth Native/prebuilt/fluidsynth soundfont Native/prebuilt/soundfont
           ffmpeg Native/prebuilt/ffmpeg scummvm Native/prebuilt/scummvm godot Native/prebuilt/godot godot3 Native/prebuilt/godot3
           kirikiri Native/prebuilt/kirikiri)
# Build order matters: ffmpeg and easyrpg reuse mkxp-z's dependencies, easyrpg links fluidsynth.
if [[ -n "${1:-}" ]]; then components=("$1")
else components=(libarchive unrar libmspack mkxp-z rgss-assets fluidsynth soundfont ffmpeg metalangle renpy853 renpy837 renpy787
                 easyrpg scummvm godot godot3 kirikiri); fi
# The Swift bridge includes a header inside the mkxp-z submodule, so a restored artefact still needs the patched tree.
[[ -e Native/mkxp-z/.git ]] && apply_patches Native/mkxp-z "$NATIVE_ROOT/Native/patches/mkxp-z"
stamps=Native/build/hydrated; mkdir -p "$stamps"
for component in $components; do
  artefact="${artefacts[$component]}" stamp="$stamps/$component"
  [[ -e "$artefact" && "$stamp" -nt "Native/manifests/$component.json" ]] && continue
  if Scripts/native/verify.sh "$component" >/dev/null 2>&1; then touch "$stamp"; continue; fi
  cache="${OMNIPLAY_NATIVE_CACHE:-}/$component"
  if [[ -n "${OMNIPLAY_NATIVE_CACHE:-}" && -d "$cache/$(basename "$artefact")" ]]; then
    echo "hydrate: restoring $component from cache"
    /bin/rm -rf "$artefact"; mkdir -p "$(dirname "$artefact")"; /bin/cp -R "$cache/$(basename "$artefact")" "$artefact"
    Scripts/native/verify.sh "$component" && { touch "$stamp"; continue; }
    echo "hydrate: cached $component did not verify; rebuilding"
  fi
  echo "hydrate: building $component (${builders[$component]})"
  ${(z)builders[$component]}
  Scripts/native/verify.sh "$component"
  touch "$stamp"
done
