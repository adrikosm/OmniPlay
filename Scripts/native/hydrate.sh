#!/bin/zsh
# hydrate.sh [component]  Makes native artefacts present and valid before a build. Order: already valid → done;
# a verified copy in $OMNIPLAY_NATIVE_CACHE/<component>/ → restore; otherwise run the component's build script.
# Fails loudly with the bootstrap instruction when a tool is missing. Quiet and fast when nothing is needed.
source "$(dirname "$0")/common.sh"
cd "$NATIVE_ROOT"
typeset -A builders artefacts
builders=(unrar Scripts/build-unrar.sh libarchive Scripts/build-libarchive.sh mkxp-z Scripts/native/build-mkxpz.sh rgss-assets Scripts/native/assemble-rgss-assets.sh
          metalangle "Scripts/native/build-renpy.sh metalangle" renpy853 "Scripts/native/build-renpy.sh 8.5.3"
          renpy837 "Scripts/native/build-renpy.sh 8.3.7" renpy787 "Scripts/native/build-renpy.sh 7.8.7" easyrpg Scripts/native/build-easyrpg.sh)
artefacts=(unrar Packages/GameImport/Native/unrar.xcframework libarchive Packages/GameImport/Native/libarchive.xcframework mkxp-z Native/prebuilt/mkxp-z rgss-assets Native/prebuilt/rgss-assets
           metalangle Native/prebuilt/renpy/metalangle renpy853 Native/prebuilt/renpy/8.5.3
           renpy837 Native/prebuilt/renpy/8.3.7 renpy787 Native/prebuilt/renpy/7.8.7 easyrpg Native/prebuilt/easyrpg)
if [[ -n "${1:-}" ]]; then components=("$1"); else components=(libarchive unrar mkxp-z rgss-assets metalangle renpy853 renpy837 renpy787 easyrpg); fi
for component in $components; do
  artefact="${artefacts[$component]}"
  if Scripts/native/verify.sh "$component" >/dev/null 2>&1; then continue; fi
  cache="${OMNIPLAY_NATIVE_CACHE:-}/$component"
  if [[ -n "${OMNIPLAY_NATIVE_CACHE:-}" && -d "$cache/$(basename "$artefact")" ]]; then
    echo "hydrate: restoring $component from cache"
    /bin/rm -rf "$artefact"; mkdir -p "$(dirname "$artefact")"; /bin/cp -R "$cache/$(basename "$artefact")" "$artefact"
    Scripts/native/verify.sh "$component" && continue
    echo "hydrate: cached $component did not verify; rebuilding"
  fi
  echo "hydrate: building $component (${builders[$component]})"
  ${(z)builders[$component]}
  Scripts/native/verify.sh "$component"
done
