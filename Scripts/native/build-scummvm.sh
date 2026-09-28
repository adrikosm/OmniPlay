#!/bin/zsh
# Builds the embedded ScummVM: Native/prebuilt/scummvm/ScummVM.xcframework, one dylib framework per SDK, holding
# ScummVM's ios7 backend with a pinned engine set behind Native/scummvm/op_scummvm.h (the only exported symbols), plus
# the engine data and GUI themes the enabled engines read (ScummVM.framework/data).
#
# Sources:
#   Native/scummvm/src                          submodule at the v2026.3.0 release tag
#   Native/patches/scummvm/*.patch              OmniPlay's host hooks (launcher → host, event hook, chroot at home,
#                                               GL from OpenGLES), applied once to the submodule
#   Native/scummvm/op_scummvm.mm                replaces the backend's main and app/scene delegates
#   libpng, FreeType, Ogg, Vorbis, Theora       reused from the mkxp-z dependency tree (Native/prebuilt/mkxp-z)
#   FluidSynth                                  the app's own @rpath/libfluidsynth.dylib (build-fluidsynth.sh), linked
#   libjpeg-turbo 3.2.0, libmad 0.15.1b         release tarballs pinned by sha256 (jpeg: Glk and Wintermute need it;
#                                               mad: AGS needs it); libjpeg-turbo's matches its GitHub release digest
#
# Engines: see ENGINES below. Adding one is a rebuild, and it counts as supported only after it has been played.
#
# Usage: build-scummvm.sh [--sdk iphoneos|iphonesimulator|all]  (default all)
source "$(dirname "$0")/common.sh"
cd "$NATIVE_ROOT"
require_xcode
require_tools make pkg-config python3 git cmake ninja curl
# ScummVM's configure and Makefiles cannot take a path with spaces. Re-run through a space-free symlink, as
# build-easyrpg.sh does.
if [[ "$NATIVE_ROOT" == *" "* && -z "${OMNIPLAY_NATIVE_LINKED:-}" ]]; then
  link="$HOME/.omniplay-native"
  [[ -L "$link" && "$(readlink "$link")" == "$NATIVE_ROOT" ]] || { /bin/rm -f "$link"; ln -s "$NATIVE_ROOT" "$link"; }
  OMNIPLAY_NATIVE_LINKED=1 exec zsh "$link/Scripts/native/build-scummvm.sh" "$@"
fi

SRC="$NATIVE_ROOT/Native/scummvm/src"
SHIM="$NATIVE_ROOT/Native/scummvm"
WORK="$NATIVE_ROOT/Native/build/scummvm"
OUT="$NATIVE_ROOT/Native/prebuilt/scummvm"
FLUID="$NATIVE_ROOT/Native/prebuilt/fluidsynth/libfluidsynth.xcframework"
ENGINES=scumm,scumm-7-8,he,sci,sci32,agi,agos,agos2,ags,glk,wintermute,sky,queen,lure,drascula,dreamweb,cge,cge2,supernova,testbed
[[ -f "$SRC/base/main.cpp" ]] || { echo "Native/scummvm/src is empty: git submodule update --init Native/scummvm/src" >&2; exit 1; }
Scripts/native/verify.sh mkxp-z >/dev/null || { echo "mkxp-z dependencies missing: Scripts/native/hydrate.sh mkxp-z" >&2; exit 1; }
[[ -d "$FLUID" ]] || { echo "FluidSynth not built: Scripts/native/build-fluidsynth.sh" >&2; exit 1; }

typeset -A url sha
url=(jpeg https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.0/libjpeg-turbo-3.2.0.tar.gz
     mad https://downloads.sourceforge.net/project/mad/libmad/0.15.1b/libmad-0.15.1b.tar.gz)
sha=(jpeg 6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e
     mad bbfac3ed6bfbc2823d3775ebb931087371e142bb0e9bb1bee51a76a6e0078690)
fetch() {  # fetch <name>: the pinned tarball, unpacked once under $WORK/src/<name>
  local file="$WORK/downloads/${url[$1]:t}"
  mkdir -p "$WORK/downloads" "$WORK/src"
  if [[ ! -f "$file" ]] || [[ "$(shasum -a 256 "$file" | cut -d' ' -f1)" != "${sha[$1]}" ]]; then
    echo "==> downloading $1"
    curl -fL --retry 3 -o "$file.part" "${url[$1]}" && /bin/mv "$file.part" "$file"
  fi
  [[ "$(shasum -a 256 "$file" | cut -d' ' -f1)" == "${sha[$1]}" ]] || { echo "$1: sha256 mismatch" >&2; exit 1; }
  [[ -d "$WORK/src/$1" ]] && return
  local tmp="$WORK/src/.unpack-$1"
  /bin/rm -rf "$tmp"; mkdir -p "$tmp"; tar xf "$file" -C "$tmp"
  /bin/mv "$tmp"/* "$WORK/src/$1"; /bin/rm -rf "$tmp"
}

# The host hooks. Each patch applies once: one already in the tree reverses cleanly and is skipped.
for patch in "$NATIVE_ROOT"/Native/patches/scummvm/*.patch(N); do
  git -C "$SRC" apply --reverse --check "$patch" 2>/dev/null && continue
  git -C "$SRC" apply "$patch" || { echo "cannot apply ${patch:t} to Native/scummvm/src" >&2; exit 1; }
done
/bin/cp -f "$SHIM/op_scummvm.mm" "$SHIM/op_scummvm.h" "$SRC/backends/platform/ios7/"

build_sdk() {  # build_sdk <sdk>: $WORK/<sdk>/ScummVM.framework
  local sdk=$1 sysroot="$(sdk_path $1)"
  local prefix="$WORK/$sdk/prefix" build="$WORK/$sdk/build" bin="$WORK/$sdk/bin"
  local deps="$NATIVE_ROOT/Native/prebuilt/mkxp-z/$sdk-$ARCH/deps"
  local target=arm64-apple-ios$IOS_MIN platform=iPhoneOS slice=ios-arm64
  [[ $sdk == iphonesimulator ]] && target=$target-simulator platform=iPhoneSimulator slice=ios-arm64-simulator
  /bin/rm -rf "$WORK/$sdk"; mkdir -p "$prefix/include" "$prefix/lib/pkgconfig" "$build" "$bin"

  echo "==> ScummVM dependencies ($sdk)"
  /bin/cp -R "$deps/include/"{freetype2,libpng16,ogg,vorbis,theora,png.h,pngconf.h,pnglibconf.h} "$prefix/include/"
  /bin/cp "$deps/lib/lib"{png16,png,freetype,ogg,vorbis,vorbisfile,theoradec}.a "$prefix/lib/"
  for pc in freetype2 libpng16 libpng ogg vorbis vorbisfile theoradec; do
    local old="$(sed -n 's/^prefix=//p' "$deps/lib/pkgconfig/$pc.pc")"
    sed "s|$old|$prefix|g" "$deps/lib/pkgconfig/$pc.pc" >"$prefix/lib/pkgconfig/$pc.pc"
  done
  mkdir -p "$prefix/include/fluidsynth"
  /bin/cp "$NATIVE_ROOT/Native/build/fluidsynth/fluidsynth-"*/include/fluidsynth/*.h \
    "$NATIVE_ROOT/Native/build/fluidsynth/build-$sdk/include/fluidsynth/version.h" "$prefix/include/fluidsynth/"
  /bin/cp "$NATIVE_ROOT/Native/build/fluidsynth/build-$sdk/include/fluidsynth.h" "$prefix/include/"
  /bin/cp "$FLUID/$slice/libfluidsynth.dylib" "$prefix/lib/"
  export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" PKG_CONFIG_PATH=

  cmake -S "$WORK/src/jpeg" -B "$build/jpeg" -G Ninja -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_ARCHITECTURES=$ARCH -DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_MIN -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_PROCESSOR=aarch64 -DCMAKE_INSTALL_PREFIX="$prefix" -DENABLE_SHARED=OFF -DWITH_TURBOJPEG=OFF -DWITH_TOOLS=OFF -DWITH_TESTS=OFF \
    >"$build/jpeg.log" 2>&1 && cmake --build "$build/jpeg" --target install >>"$build/jpeg.log" 2>&1 ||
    { tail -20 "$build/jpeg.log" >&2; exit 1; }
  # libmad's autotools predate arm64; its eleven files build directly. The shipped mad.h is configured for 32-bit x86,
  # so the 64-bit fixed-point variant is selected in a copy.
  mkdir -p "$build/mad"
  sed -e 's/^# define FPM_INTEL$/# define FPM_64BIT/' -e 's/^# define SIZEOF_LONG 4$/# define SIZEOF_LONG 8/' \
    "$WORK/src/mad/mad.h" >"$prefix/include/mad.h"
  printf '%s\n' '#define FPM_64BIT 1' '#define SIZEOF_INT 4' '#define SIZEOF_LONG 8' '#define SIZEOF_LONG_LONG 8' \
    '#define HAVE_ASSERT_H 1' '#define HAVE_LIMITS_H 1' '#define HAVE_UNISTD_H 1' '#define HAVE_FCNTL_H 1' \
    '#define HAVE_ERRNO_H 1' '#define HAVE_SYS_TYPES_H 1' >"$build/mad/config.h"
  local c
  for c in bit decoder fixed frame huffman layer12 layer3 stream synth timer version; do
    xcrun --sdk $sdk clang -target $target -isysroot "$sysroot" -O2 -DHAVE_CONFIG_H -I"$build/mad" -w \
      -c "$WORK/src/mad/$c.c" -o "$build/mad/$c.o"
  done
  xcrun ar rcs "$prefix/lib/libmad.a" "$build/mad/"*.o

  # configure takes a compiler command, not a command line: small wrappers pin the SDK and target.
  local tool
  for tool in clang clang++; do
    printf '#!/bin/sh\nexec xcrun --sdk %s %s -target %s -isysroot "%s" "$@"\n' $sdk $tool $target "$sysroot" >"$bin/$tool"
    chmod +x "$bin/$tool"
  done

  echo "==> ScummVM $sdk (configure)"
  (cd "$build" && CC="$bin/clang" CXX="$bin/clang++" "$SRC/configure" --host=ios7-arm64 --enable-release \
    --disable-debug --disable-all-engines --enable-engine=$ENGINES --disable-detection-full \
    --with-png-prefix="$prefix" --with-freetype2-prefix="$prefix" --with-ogg-prefix="$prefix" \
    --with-vorbis-prefix="$prefix" --with-theoradec-prefix="$prefix" --with-fluidsynth-prefix="$prefix" \
    --with-jpeg-prefix="$prefix" --with-mad-prefix="$prefix" --disable-flac --disable-mpeg2 --disable-faad --disable-a52 --disable-gif \
    --disable-fribidi --disable-libcurl --disable-sdlnet --disable-cloud --disable-tts --disable-mikmod \
    --disable-openmpt --disable-mpcdec --disable-vpx --disable-discord --disable-lua --disable-eventrecorder \
    --disable-updates >"$build/configure.log" 2>&1) || { tail -30 "$build/configure.log" >&2; exit 1; }
  # The ios7 host names GNU-style binutils and a 7.1 minimum that fights the simulator target; the SDK's own tools
  # and the wrappers' target stand in. OMNIPLAY_HOST switches the patch and the shim on, and the executable becomes
  # the framework's dylib exporting only op_scummvm_*.
  python3 - "$build/config.mk" "$SHIM/exports.txt" <<'EOF'
import re, sys
path, exports = sys.argv[1], sys.argv[2]
s = open(path).read()
s = s.replace('-miphoneos-version-min=7.1 -arch arm64', '')
s = re.sub(r'^AR := .*$', 'AR := xcrun ar cr', s, flags=re.M)
s = re.sub(r'^RANLIB := .*$', 'RANLIB := xcrun ranlib', s, flags=re.M)
s = re.sub(r'^STRIP := .*$', 'STRIP := xcrun strip', s, flags=re.M)
s += '\nOMNIPLAY_HOST = 1\nDEFINES += -DOMNIPLAY_HOST\n'
s += ('LDFLAGS += -dynamiclib -install_name @rpath/ScummVM.framework/ScummVM -Wl,-rpath,@loader_path/.. '
      '-Wl,-dead_strip -Wl,-exported_symbols_list,' + exports + '\n')
open(path, 'w').write(s)
EOF
  grep -q "USE_FLUIDSYNTH" "$build/config.h" && grep -q "#define USE_FLUIDSYNTH" "$build/config.h" ||
    echo "warning: FluidSynth not enabled for $sdk (see $build/configure.log)" >&2

  echo "==> ScummVM $sdk (build)"
  make -C "$build" -j$(sysctl -n hw.ncpu) EXECUTABLE=ScummVM ScummVM >"$build/make.log" 2>&1 ||
    { grep -E "error:" "$build/make.log" | head -20 >&2 || true; echo "build failed: $build/make.log" >&2; exit 1; }

  local fw="$WORK/$sdk/ScummVM.framework"
  mkdir -p "$fw/data"
  /bin/cp "$build/ScummVM" "$fw/ScummVM"
  # Engine data and themes for the enabled engines, as ScummVM's own packaging lists them.
  local f
  for f in $(make -s -C "$build" print-dists); do
    # Licence and credit files go to LICENSES/scummvm.txt, not into the app.
    [[ -f "$f" && "$f" != *.md && "$f" != *.txt && "$f" != */doc/* && "${f:t}" != (AUTHORS|COPYING*|COPYRIGHT*) ]] &&
      /bin/cp -f "$f" "$fw/data/"
  done
  codesign -f -s - "$fw/ScummVM" 2>/dev/null
  sed -e "s/@NAME@/ScummVM/g" -e "s/@VERSION@/$(make -s -C "$build" print-version)/g" -e "s/@PLATFORM@/$platform/g" \
    -e "s/@MIN@/$IOS_MIN/g" -e "s/com.omniplay.engine.easyrpg/com.omniplay.engine.scummvm/" \
    "$NATIVE_ROOT/Native/EasyRPG/Info.plist.in" >"$fw/Info.plist"
}

WANT=all
[[ "${1:-}" == "--sdk" ]] && WANT="$2"
sdks=(iphoneos iphonesimulator); [[ $WANT != all ]] && sdks=($WANT)
for name in jpeg mad; do fetch $name; done
for sdk in $sdks; do build_sdk $sdk; done
if [[ $WANT == all ]]; then
  /bin/rm -rf "$OUT"; mkdir -p "$OUT"
  xcodebuild -create-xcframework -framework "$WORK/iphoneos/ScummVM.framework" \
    -framework "$WORK/iphonesimulator/ScummVM.framework" -output "$OUT/ScummVM.xcframework" >/dev/null
  Scripts/native/manifest.sh scummvm Native/prebuilt/scummvm Native/scummvm/src
fi
echo "built $OUT"
