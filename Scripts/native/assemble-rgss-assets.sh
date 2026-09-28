#!/bin/zsh
# Assembles what the mkxp-z engine reads from its host bundle at run time into Native/prebuilt/rgss-assets/.
# The two names are the engine's, not ours: filesystemImplIOS.mm looks for <bundle>/Assets.bundle for shaders,
# fonts, preload/postload Ruby, gamecontrollerdb and the CA bundle, and binding-mri.cpp pushes
# <bundle>/Ruby/<rubylibdir> onto $LOAD_PATH. Both are copied to the app's resource root by project.yml.
# Everything comes from the pinned submodule and the fork's pinned dependency release; nothing is hand-edited.
source "$(dirname "$0")/common.sh"
cd "$NATIVE_ROOT"
ENGINE="Native/mkxp-z"
DEPS="Native/prebuilt/mkxp-z/iphonesimulator-arm64/deps"
[[ -d "$ENGINE/shader" ]] || { echo "Native/mkxp-z is empty: git submodule update --init Native/mkxp-z" >&2; exit 1; }
[[ -d "$DEPS/ruby-stdlib" ]] || { echo "run Scripts/native/build-mkxpz.sh first (Ruby stdlib comes with its dependency release)" >&2; exit 1; }
OUT="Native/prebuilt/rgss-assets"
ASSETS="$OUT/Assets.bundle"
/bin/rm -rf "$OUT"; mkdir -p "$ASSETS/Shaders" "$ASSETS/Fonts" "$ASSETS/Preload" "$ASSETS/Postload" "$OUT/Ruby"
/bin/cp "$ENGINE"/shader/*.frag "$ENGINE"/shader/*.vert "$ENGINE"/shader/*.h "$ASSETS/Shaders/"
/bin/cp "$ENGINE"/assets/liberation.ttf "$ENGINE"/assets/wqymicrohei.ttf "$ASSETS/Fonts/"
/bin/cp "$ENGINE"/assets/gamecontrollerdb.txt "$ENGINE"/assets/cacert.pem "$ASSETS/"
/bin/cp "$ENGINE"/scripts/preload/*.rb "$ASSETS/Preload/"
/bin/cp "$ENGINE"/scripts/postload/*.rb "$ASSETS/Postload/"
/bin/cp -R "$DEPS"/ruby-stdlib/. "$OUT/Ruby/"
Scripts/native/manifest.sh rgss-assets "$OUT" Native/mkxp-z
echo "assembled $OUT"
