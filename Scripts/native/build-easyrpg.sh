#!/bin/zsh
# Builds the embedded EasyRPG Player (RPG Maker 2000/2003): Native/prebuilt/easyrpg/EasyRPG.xcframework, one dylib
# framework per SDK, the way the Ren'Py engines are built: the Player, liblcf and their codecs linked behind
# Native/EasyRPG/op_easyrpg.h (the only exported symbols), with a private SDL2 whose Objective-C classes are renamed
# so it can share the process with mkxp-z's and Ren'Py's copies.
#
# Sources:
#   Native/easyrpg/player, Native/easyrpg/liblcf   submodules at the Player 0.8.1.1 and liblcf 0.8.1 tags
#   fmt, inih, mpg123, speexdsp                     release tarballs, pinned by sha256 (the versions EasyRPG's
#                                                   own buildscripts use)
#   ICU 78.1 public headers                         unicode-org/icu at release-78.1, headers only: the code is the
#                                                   system libicucore (ICU 78.1 in the iOS 27 SDK, unrenamed C API),
#                                                   which carries the Shift-JIS and other converters liblcf needs
#   SDL2, pixman, libpng, freetype, ogg, vorbis     reused from the mkxp-z dependency tree (Native/prebuilt/mkxp-z)
#   FluidSynth                                      the app's own @rpath/libfluidsynth.dylib (build-fluidsynth.sh),
#                                                   linked, not copied: MIDI is RPG Maker 2000/2003's music format
#
# Usage: build-easyrpg.sh [--sdk iphoneos|iphonesimulator|all]  (default all)
source "$(dirname "$0")/common.sh"
cd "$NATIVE_ROOT"
require_xcode
require_tools cmake ninja curl unzip python3 git make
# speexdsp's autotools build cannot take a path with spaces. Re-run through a space-free symlink, as build-mkxpz.sh
# does; `pwd` keeps the logical path, so every derived path stays clean.
if [[ "$NATIVE_ROOT" == *" "* && -z "${OMNIPLAY_NATIVE_LINKED:-}" ]]; then
  link="$HOME/.omniplay-native"
  [[ -L "$link" && "$(readlink "$link")" == "$NATIVE_ROOT" ]] || { /bin/rm -f "$link"; ln -s "$NATIVE_ROOT" "$link"; }
  OMNIPLAY_NATIVE_LINKED=1 exec zsh "$link/Scripts/native/build-easyrpg.sh" "$@"
fi

PLAYER="$NATIVE_ROOT/Native/easyrpg/player"
LIBLCF="$NATIVE_ROOT/Native/easyrpg/liblcf"
SHIM="$NATIVE_ROOT/Native/EasyRPG"
WORK="$NATIVE_ROOT/Native/build/easyrpg"
OUT="$NATIVE_ROOT/Native/prebuilt/easyrpg"
[[ -f "$PLAYER/src/player.cpp" && -f "$LIBLCF/src/encoder.cpp" ]] ||
  { echo "Native/easyrpg is empty: git submodule update --init Native/easyrpg/player Native/easyrpg/liblcf" >&2; exit 1; }
Scripts/native/verify.sh mkxp-z >/dev/null || { echo "mkxp-z dependencies missing: Scripts/native/hydrate.sh mkxp-z" >&2; exit 1; }
FLUID="$NATIVE_ROOT/Native/build/fluidsynth"
[[ -f "$FLUID/build-iphoneos/include/fluidsynth/version.h" ]] ||
  { echo "FluidSynth not built: Scripts/native/build-fluidsynth.sh" >&2; exit 1; }

typeset -A url sha
url=(fmt https://github.com/fmtlib/fmt/releases/download/12.1.0/fmt-12.1.0.zip
     inih https://github.com/benhoyt/inih/archive/refs/tags/r62.tar.gz
     mpg123 https://www.mpg123.de/download/mpg123-1.33.4.tar.bz2
     speexdsp https://downloads.xiph.org/releases/speex/speexdsp-1.2.1.tar.gz)
sha=(fmt 695fd197fa5aff8fc67b5f2bbc110490a875cdf7a41686ac8512fb480fa8ada7
     inih 9c15fa751bb8093d042dae1b9f125eb45198c32c6704cd5481ccde460d4f8151
     mpg123 3ae8c9ff80a97bfc0e22e89fbcd74687eca4fc1db315b12607f27f01cb5a47d9
     speexdsp 8c777343e4a6399569c72abc38a95b24db56882c83dbdb6c6424a5f4aeb54d3d)
ICU_TAG=release-78.1 ICU_COMMIT=049e0d6a420629ac7db77256987d083a563287b5

fetch() {  # fetch <name>: the pinned tarball, unpacked once under $WORK/src
  local file="$WORK/downloads/${url[$1]:t}"
  mkdir -p "$WORK/downloads" "$WORK/src"
  if [[ ! -f "$file" ]] || [[ "$(shasum -a 256 "$file" | cut -d' ' -f1)" != "${sha[$1]}" ]]; then
    echo "==> downloading $1"
    curl -fL --retry 3 -o "$file.part" "${url[$1]}" && /bin/mv "$file.part" "$file"
  fi
  [[ "$(shasum -a 256 "$file" | cut -d' ' -f1)" == "${sha[$1]}" ]] || { echo "$1: sha256 mismatch" >&2; exit 1; }
  [[ -d "$WORK/src/$1" ]] && return
  local tmp="$WORK/src/.unpack-$1"
  /bin/rm -rf "$tmp"; mkdir -p "$tmp"
  case $file in
    *.zip) unzip -q "$file" -d "$tmp" ;;
    *) tar xf "$file" -C "$tmp" ;;
  esac
  /bin/mv "$tmp"/* "$WORK/src/$1"; /bin/rm -rf "$tmp"
}

icu_headers() {  # the public headers of the ICU release the SDK's libicucore is built from
  local repo="$WORK/src/icu"
  if [[ "$(git -C "$repo" rev-parse HEAD 2>/dev/null)" != "$ICU_COMMIT" ]]; then
    /bin/rm -rf "$repo"
    git clone -q --depth 1 --branch $ICU_TAG --filter=blob:none --sparse https://github.com/unicode-org/icu.git "$repo"
    git -C "$repo" sparse-checkout set icu4c/source/common/unicode icu4c/source/i18n/unicode
  fi
  [[ "$(git -C "$repo" rev-parse HEAD)" == "$ICU_COMMIT" ]] || { echo "ICU $ICU_TAG is not $ICU_COMMIT" >&2; exit 1; }
}

ios_cmake() {  # ios_cmake <source> <build dir> [cmake args...]: configure, build and install into $prefix
  local src=$1 dir=$2; shift 2
  cmake -S "$src" -B "$dir" -G Ninja -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sysroot" -DCMAKE_OSX_ARCHITECTURES=$ARCH \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_MIN -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_FIND_ROOT_PATH="$prefix" -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
    -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON "$@" >"$dir.log" 2>&1 ||
    { tail -40 "$dir.log" >&2; echo "configure failed: $dir.log" >&2; exit 1; }
  cmake --build "$dir" >>"$dir.log" 2>&1 || { tail -40 "$dir.log" >&2; echo "build failed: $dir.log" >&2; exit 1; }
}

build_sdk() {  # build_sdk <sdk>: $OUT-bound framework under $WORK/<sdk>/EasyRPG.framework
  local sdk=$1
  sysroot="$(sdk_path $sdk)" prefix="$WORK/$sdk/prefix"
  local deps="$NATIVE_ROOT/Native/prebuilt/mkxp-z/$sdk-$ARCH/deps" build="$WORK/$sdk/build"
  local target=arm64-apple-ios$IOS_MIN platform=iPhoneOS
  [[ $sdk == iphonesimulator ]] && target=$target-simulator platform=iPhoneSimulator
  /bin/rm -rf "$WORK/$sdk"; mkdir -p "$prefix/include" "$prefix/lib/pkgconfig" "$prefix/lib/cmake" "$build"

  echo "==> EasyRPG dependencies ($sdk)"
  # From the mkxp-z tree. Its pkg-config files carry the fork's CI paths, so they are rewritten to this prefix;
  # SDL2main is left out, which keeps SDL's own main() and app delegate out of the framework. Vorbis's CMake config
  # is left out too: it wants an Ogg config the tree lacks, and the Player's own FindVorbis needs neither.
  /bin/cp -R "$deps/include/"{SDL2,pixman-1,freetype2,libpng16,ogg,vorbis,png.h,pngconf.h,pnglibconf.h} "$prefix/include/"
  /bin/cp "$deps/lib/lib"{SDL2,pixman-1,png16,png,freetype,ogg,vorbis,vorbisfile}.a "$prefix/lib/"
  mkdir -p "$prefix/lib/cmake/SDL2"
  /bin/cp "$deps/lib/cmake/SDL2/"{SDL2Config,SDL2ConfigVersion,SDL2staticTargets,SDL2staticTargets-release,sdlfind}.cmake "$prefix/lib/cmake/SDL2/"
  for pc in sdl2 pixman-1 freetype2 libpng16 libpng ogg vorbis vorbisfile; do
    local old="$(sed -n 's/^prefix=//p' "$deps/lib/pkgconfig/$pc.pc")"
    sed "s|$old|$prefix|g" "$deps/lib/pkgconfig/$pc.pc" >"$prefix/lib/pkgconfig/$pc.pc"
  done
  export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" PKG_CONFIG_PATH=

  # ICU: upstream 78.1 headers, then the SDK's own copies on top so Apple's configuration (unrenamed API) wins.
  mkdir -p "$prefix/include/unicode"
  /bin/cp "$WORK/src/icu/icu4c/source/common/unicode/"*.h "$WORK/src/icu/icu4c/source/i18n/unicode/"*.h "$prefix/include/unicode/"
  /bin/cp "$sysroot/usr/include/unicode/"*.h "$prefix/include/unicode/"
  # FluidSynth: its public headers (version.h is generated per build) and the dylib the app embeds.
  local fluid_slice=ios-arm64; [[ $sdk == iphonesimulator ]] && fluid_slice=ios-arm64-simulator
  mkdir -p "$prefix/include/fluidsynth"
  /bin/cp "$FLUID/fluidsynth-"*/include/fluidsynth/*.h "$FLUID/build-$sdk/include/fluidsynth/version.h" "$prefix/include/fluidsynth/"
  /bin/cp "$FLUID/build-$sdk/include/fluidsynth.h" "$prefix/include/"
  local fluid=(-DFLUIDSYNTH_INCLUDE_DIR="$prefix/include"
               -DFLUIDSYNTH_LIBRARY="$NATIVE_ROOT/Native/prebuilt/fluidsynth/libfluidsynth.xcframework/$fluid_slice/libfluidsynth.dylib")

  local icu=(-DICU_INCLUDE_DIR="$prefix/include" -DICU_UC_LIBRARY_RELEASE="$sysroot/usr/lib/libicucore.tbd"
             -DICU_I18N_LIBRARY_RELEASE="$sysroot/usr/lib/libicucore.tbd" -DICU_DATA_LIBRARY_RELEASE="$sysroot/usr/lib/libicucore.tbd")

  ios_cmake "$WORK/src/fmt" "$build/fmt" -DFMT_DOC=OFF -DFMT_TEST=OFF
  cmake --install "$build/fmt" >/dev/null
  ios_cmake "$WORK/src/mpg123/ports/cmake" "$build/mpg123" -DBUILD_LIBOUT123=OFF -DBUILD_PROGRAMS=OFF -DNETWORK=OFF
  cmake --install "$build/mpg123" >/dev/null

  local cc=(xcrun --sdk $sdk clang -target $target -isysroot "$sysroot" -O2 -fPIC)
  mkdir -p "$build/inih"  # two files; its only build system is meson
  $cc -c "$WORK/src/inih/ini.c" -o "$build/inih/ini.o" && ar rcs "$prefix/lib/libinih.a" "$build/inih/ini.o"
  /bin/cp "$WORK/src/inih/ini.h" "$prefix/include/"

  mkdir -p "$build/speexdsp"
  (cd "$build/speexdsp" && CC="${cc[*]}" "$WORK/src/speexdsp/configure" --host=aarch64-apple-darwin --prefix="$prefix" \
    --disable-shared --disable-neon --disable-examples >"$build/speexdsp.log" 2>&1 && make -j8 install >>"$build/speexdsp.log" 2>&1) ||
    { tail -30 "$build/speexdsp.log" >&2; exit 1; }

  echo "==> liblcf ($sdk)"
  # liblcf reaches the normalizer's C API through <unicode/normalizer2.h>, which only includes <unicode/unorm2.h>
  # when ICU's C++ API is shown; Apple's headers hide it (libicucore exports only C), so include it directly.
  ios_cmake "$LIBLCF" "$build/liblcf" -DLIBLCF_WITH_XML=OFF -DLIBLCF_ENABLE_TOOLS=OFF -DLIBLCF_ENABLE_TESTS=OFF \
    -DLIBLCF_UPDATE_MIMEDB=OFF -DLIBLCF_ENABLE_INSTALL=ON -DCMAKE_CXX_FLAGS="-I$prefix/include -include unicode/unorm2.h" $icu
  cmake --install "$build/liblcf" >/dev/null

  echo "==> EasyRPG Player ($sdk)"
  ios_cmake "$SHIM" "$build/player" -DEASYRPG_PLAYER_DIR="$PLAYER" -DPLAYER_TARGET_PLATFORM=SDL2 -DPLAYER_BUILD_EXECUTABLE=OFF \
    -DPLAYER_ENABLE_TESTS=OFF -DPLAYER_WITH_HARFBUZZ=OFF -DPLAYER_WITH_LHASA=OFF -DPLAYER_WITH_NLOHMANN_JSON=OFF \
    -DPLAYER_WITH_LIBSNDFILE=OFF -DPLAYER_WITH_OPUS=OFF -DPLAYER_WITH_WILDMIDI=OFF -DPLAYER_WITH_FLUIDSYNTH=ON \
    -DPLAYER_WITH_FLUIDLITE=OFF -DPLAYER_WITH_XMP=OFF -DPLAYER_WITH_SAMPLERATE=OFF -DPLAYER_WITH_NATIVE_MIDI=OFF \
    -DCMAKE_SHARED_LINKER_FLAGS="-framework UIKit -framework Foundation -framework CoreFoundation -lbz2 -Wl,-rpath,@loader_path/.." \
    -DCMAKE_SKIP_RPATH=ON $icu $fluid

  local fw="$WORK/$sdk/EasyRPG.framework" version="$(sed -n 's/^project(EasyRPG_Player VERSION \([0-9.]*\).*/\1/p' "$PLAYER/CMakeLists.txt")"
  mkdir -p "$fw"
  /bin/cp "$build/player/EasyRPG" "$fw/EasyRPG"
  python3 Scripts/native/rename-objc-classes.py "$fw/EasyRPG" ERP
  sed -e "s/@NAME@/EasyRPG/g" -e "s/@VERSION@/$version/g" -e "s/@PLATFORM@/$platform/g" -e "s/@MIN@/$IOS_MIN/g" \
    "$SHIM/Info.plist.in" >"$fw/Info.plist"
  # Sign the bundle, not the binary, so the signing identifier is CFBundleIdentifier (iOS refuses a mismatch).
  codesign -f -s - "$fw" 2>/dev/null
}

WANT=all
[[ "${1:-}" == "--sdk" ]] && WANT="$2"
sdks=(iphoneos iphonesimulator); [[ $WANT != all ]] && sdks=($WANT)
for name in fmt inih mpg123 speexdsp; do fetch $name; done
icu_headers
for sdk in $sdks; do build_sdk $sdk; done
if [[ $WANT == all ]]; then
  /bin/rm -rf "$OUT"; mkdir -p "$OUT"
  xcodebuild -create-xcframework -framework "$WORK/iphoneos/EasyRPG.framework" \
    -framework "$WORK/iphonesimulator/EasyRPG.framework" -output "$OUT/EasyRPG.xcframework" >/dev/null
  Scripts/native/manifest.sh easyrpg Native/prebuilt/easyrpg Native/easyrpg/player Native/easyrpg/liblcf
fi
echo "built $OUT"
