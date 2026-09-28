#!/bin/zsh
# Builds the mkxp-z Apple mobile fork (Native/mkxp-z, pinned tag) into Native/prebuilt/mkxp-z/<sdk>-arm64/:
#   libmkxpz-core.a                 the engine core (src/), compiled by the fork's own recipe
#   mkxp18-merged.o mkxp19-merged.o mkxp31-merged.o
#                                   one Ruby binding per Ruby, each with its libruby merged and hidden
#   deps/                           the fork's pinned dependency libraries, headers and Ruby stdlib subsets
# The fork's tools are the single source of truth for the compile; this script only supplies SDK settings,
# paths and the manifest. Usage: build-mkxpz.sh [--sdk iphoneos|iphonesimulator|all]  (default all)
source "$(dirname "$0")/common.sh"
cd "$NATIVE_ROOT"
require_xcode
# The fork's scripts pass include paths unquoted, so a repository path with spaces breaks them. Re-run through a
# space-free symlink; `pwd` keeps the logical path, so every derived path stays clean.
if [[ "$NATIVE_ROOT" == *" "* && -z "${OMNIPLAY_NATIVE_LINKED:-}" ]]; then
  link="$HOME/.omniplay-native"
  [[ -L "$link" && "$(readlink "$link")" == "$NATIVE_ROOT" ]] || { /bin/rm -f "$link"; ln -s "$NATIVE_ROOT" "$link"; }
  OMNIPLAY_NATIVE_LINKED=1 exec zsh "$link/Scripts/native/build-mkxpz.sh" "$@"
fi
ENGINE="$NATIVE_ROOT/Native/mkxp-z"
[[ -f "$ENGINE/tools/build-core-ios.sh" ]] || { echo "Native/mkxp-z is empty: git submodule update --init Native/mkxp-z" >&2; exit 1; }
WANT=all
[[ "${1:-}" == "--sdk" ]] && WANT="$2"
sdks=(iphoneos iphonesimulator); [[ $WANT != all ]] && sdks=($WANT)
OUTROOT="$NATIVE_ROOT/Native/prebuilt/mkxp-z"
# The fork's hmode7 submodule is pinned through an SSH URL; a clone without GitHub keys needs the HTTPS mirror.
git -C "$ENGINE" config submodule.hmode7.url https://github.com/mateo-m/hmode7-apple-mobile.git
[[ -f "$ENGINE/hmode7/src/hm7_apply_opacity.h" ]] || git -C "$ENGINE" submodule update --init --depth 1 hmode7
# OmniPlay's fixes to the fork live in Native/patches/mkxp-z, since the submodule stays on the fork's commit. Each
# applies once: a patch already in the tree reverses cleanly and is skipped.
for patch in "$NATIVE_ROOT"/Native/patches/mkxp-z/*.patch(N); do
  git -C "$ENGINE" apply --reverse --check "$patch" 2>/dev/null && continue
  git -C "$ENGINE" apply "$patch" || { echo "cannot apply ${patch:t} to Native/mkxp-z" >&2; exit 1; }
done
"$ENGINE/tools/fetch-deps-ios.sh" --sdk "$WANT"
for sdk in $sdks; do
  tree="$ENGINE/deps/build-$sdk-$ARCH"; angle="$ENGINE/deps/ANGLE/$sdk"
  [[ -d "$tree/lib" && -d "$angle/lib" ]] || { echo "dependencies for $sdk missing under Native/mkxp-z/deps" >&2; exit 1; }
  out="$OUTROOT/$sdk-$ARCH"; obj="$NATIVE_ROOT/Native/build/mkxp-z/$sdk"
  mkdir -p "$out" "$obj"
  includes=(--include "$tree/include" --include "$tree/include/AL" --include "$tree/include/SDL2" --include "$tree/include/pixman-1"
            --include "$tree/include/uchardet" --include "$tree/include/freetype2" --include "$angle/include")
  echo "==> mkxp-z core ($sdk)"
  "$ENGINE/tools/build-core-ios.sh" --sdk "$sdk" --arch "$ARCH" --min-os "$IOS_MIN" --obj "$obj/core" --out "$out" "${includes[@]}"
  binding() {
    echo "==> mkxp-z binding ruby$1 ($sdk)"
    "$ENGINE/tools/build-binding-ios.sh" --ruby "$1" --sdk "$sdk" --arch "$ARCH" --min-os "$IOS_MIN" \
      --obj "$obj/binding$1" --out "$out" --scratch "$obj" --ruby-include "$tree/include/$2" \
      --static-lib "$tree/lib/$3" --ext-lib "$tree/lib/$4" "${includes[@]}"
  }
  binding 31 ruby31 libruby.3.1-static.a libruby.3.1-ext.a
  binding 19 ruby19 libruby19-static.a libruby19-ext.a
  binding 18 ruby18 libruby18-static.a libruby18-ext.a
  # The dependency libraries the app links, kept beside the engine objects so one manifest covers everything.
  /bin/rm -rf "$out/deps"; mkdir -p "$out/deps"
  /bin/cp -R "$tree/lib" "$out/deps/lib"; /bin/cp -R "$tree/include" "$out/deps/include"; /bin/cp -R "$tree/ruby-stdlib" "$out/deps/ruby-stdlib"
  /bin/cp -R "$angle/lib" "$out/deps/angle-lib"; /bin/cp -R "$angle/include" "$out/deps/angle-include"
done
[[ $WANT == all ]] && Scripts/native/manifest.sh mkxp-z Native/prebuilt/mkxp-z Native/mkxp-z
echo "built $OUTROOT"
