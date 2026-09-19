#!/bin/zsh
# hydrate.sh [component]  Makes native artefacts present and valid before a build. Order: already valid → done;
# a verified copy in $OMNIPLAY_NATIVE_CACHE/<component>/ → restore; otherwise run the component's build script.
# Fails loudly with the bootstrap instruction when a tool is missing. Quiet and fast when nothing is needed.
source "$(dirname "$0")/common.sh"
cd "$NATIVE_ROOT"
typeset -A builders artefacts
builders=(libarchive Scripts/build-libarchive.sh)
artefacts=(libarchive Packages/GameImport/Native/libarchive.xcframework)
components=(${1:-${(k)builders}})
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
  "${builders[$component]}"
  Scripts/native/verify.sh "$component"
done
