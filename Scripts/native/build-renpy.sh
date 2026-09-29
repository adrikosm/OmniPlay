#!/bin/zsh
# Builds the embedded Ren'Py engines: Native/prebuilt/renpy/<version>/RenPy<NNN>.xcframework, one dylib framework
# per engine, and Native/prebuilt/renpy/metalangle/MetalANGLE.xcframework, which all of them link.
#
# Inputs are Ren'Py's own release packages, downloaded from renpy.org and pinned by the sha256 Ren'Py publishes in
# each release's signed checksums.txt:
#   renpy-<v>-renios.zip   the static libraries renpy-build produced for that release (device, and a simulator
#                          slice), plus MetalANGLE: the set Ren'Py's own iOS projects link
#   renpy-<v>-sdk.tar.bz2  the engine tree (renpy/, renpy.py) and the Python standard library for it
# renpy-build itself only cross-compiles its iOS target on Linux; these packages are that output, per release.
#
# Each framework holds a dylib that links the whole static set behind op_renpy.h (the only exported symbols; the
# prototype's main.c is replaced by Native/RenPy/op_renpy.c) and a base/ folder that launcher_main finds beside
# the binary: OmniPlay's main.py and host glue from Native/RenPy/base, Ren'Py's renpy.py as launcher.py,
# the engine tree with sources dropped as Ren'Py's own distributor does, and the standard library.
#
# Usage: build-renpy.sh [8.5.3|8.3.7|7.8.7|all|metalangle]  (default all)
source "$(dirname "$0")/common.sh"
cd "$NATIVE_ROOT"
require_xcode
require_tools curl unzip python3

typeset -A renios_sha sdk_sha python_line
renios_sha=(
  8.5.3 c4fae153e8276ed0faed5e84ea3e0b7c4bf337f0e3208e9130c6a41748a83b2b
  8.3.7 5b36af73640f2cb9ec68b5c2d90fc34ab2ac6832af45fd97c4c852e316ac779d
  7.8.7 faaabec4ec65efa8803a5a7222f6e40183c5fe8354c1ee4eeb78e978826cee86
)
sdk_sha=(
  8.5.3 eb0a9be7f0fb13632fe25ceade9a8bed5a1b4d6b6e83bd19eeeb29e1a1bb4a45
  8.3.7 13a221c1e2ac6730e7d369fef93153b79940fa8ae3ec3660abd94c67dea58f4e
  7.8.7 65466068af7c181a143f13d84b0ddf7a6aa58dd8d26e7ccd97cdcadecabcae5a
)
python_line=(8.5.3 python3.12 8.3.7 python3.9 7.8.7 python2.7)
# One MetalANGLE for every engine: the builds in the three packages export the same symbols, and two copies with
# one install name and the same Objective-C classes cannot share a process. The newest package's copy wins.
METALANGLE_FROM=8.5.3

WORK="$NATIVE_ROOT/Native/build/renpy"
OUT="$NATIVE_ROOT/Native/prebuilt/renpy"
SRC="$NATIVE_ROOT/Native/RenPy"

# The upstream prototype's link order; libraries a package does not ship are skipped.
LINK_ORDER=(renpython renpy PYTHON assimp avformat avcodec swscale swresample avutil SDL2_image SDL2 avif aom yuv turbojpeg
            png16 webp harfbuzz brotlidec brotlicommon fribidi freetype ffi ssl crypto lzma bz2 z)
FRAMEWORKS=(UIKit Foundation CoreFoundation CoreGraphics QuartzCore AudioToolbox AVFoundation ImageIO MobileCoreServices CoreServices
            CoreMotion GameController Metal)
WEAK_FRAMEWORKS=(CoreHaptics CoreBluetooth)

fetch() {  # fetch <file> <sha256> <url>
  local file="$WORK/downloads/$1"
  mkdir -p "$WORK/downloads"
  if [[ ! -f "$file" ]] || [[ "$(shasum -a 256 "$file" | cut -d' ' -f1)" != "$2" ]]; then
    echo "==> downloading $1"
    curl -fL --retry 3 -o "$file.part" "$3"
    /bin/mv "$file.part" "$file"
  fi
  [[ "$(shasum -a 256 "$file" | cut -d' ' -f1)" == "$2" ]] || { echo "$1: sha256 mismatch" >&2; exit 1; }
}

unpack() {  # unpack <version>: renios/ and renpy-<v>-sdk/ under Native/build/renpy/<v>
  local v=$1 dir="$WORK/$1"
  fetch "renpy-$v-renios.zip" "${renios_sha[$v]}" "https://www.renpy.org/dl/$v/renpy-$v-renios.zip"
  fetch "renpy-$v-sdk.tar.bz2" "${sdk_sha[$v]}" "https://www.renpy.org/dl/$v/renpy-$v-sdk.tar.bz2"
  mkdir -p "$dir"
  [[ -d "$dir/renios/prototype/prebuilt" ]] || unzip -q -o "$WORK/downloads/renpy-$v-renios.zip" -d "$dir"
  [[ -d "$dir/renpy-$v-sdk/renpy" ]] || tar xjf "$WORK/downloads/renpy-$v-sdk.tar.bz2" -C "$dir"
}

metalangle() {
  local v=$METALANGLE_FROM
  unpack $v
  local from="$WORK/$v/renios/prototype/Frameworks/MetalANGLE.xcframework" stage="$WORK/metalangle" out="$OUT/metalangle"
  /bin/rm -rf "$stage" "$out"; mkdir -p "$stage/iphoneos" "$stage/iphonesimulator" "$out"
  # Only the arm64 slices: the package also carries armv7, i386 and x86_64.
  /bin/cp -R "$from/ios-arm64_armv7/MetalANGLE.framework" "$stage/iphoneos/"
  /bin/cp -R "$from/ios-arm64_i386_x86_64-simulator/MetalANGLE.framework" "$stage/iphonesimulator/"
  for sdk in iphoneos iphonesimulator; do
    local bin="$stage/$sdk/MetalANGLE.framework/MetalANGLE"
    lipo "$bin" -thin arm64 -output "$bin.thin" && /bin/mv "$bin.thin" "$bin"
  done
  xcodebuild -create-xcframework -framework "$stage/iphoneos/MetalANGLE.framework" \
    -framework "$stage/iphonesimulator/MetalANGLE.framework" -output "$out/MetalANGLE.xcframework" >/dev/null
  Scripts/native/manifest.sh metalangle Native/prebuilt/renpy/metalangle
}

assemble_base() {  # assemble_base <version> <dest>: the base/ folder launcher_main runs
  local v=$1 base=$2 sdkdir="$WORK/$1/renpy-$1-sdk" py=${python_line[$1]}
  /bin/rm -rf "$base"; mkdir -p "$base/lib"
  /bin/cp -R "$sdkdir/renpy" "$base/renpy"
  /bin/cp -R "$sdkdir/lib/$py" "$base/lib/$py"
  /bin/cp "$sdkdir/renpy.py" "$base/launcher.py"
  # Games built from the SDK tree (The Question, the tutorial) add renpy_base/sdk-fonts to their search path.
  /bin/cp -R "$sdkdir/sdk-fonts" "$base/sdk-fonts"
  /bin/cp "$SRC/base/main.py" "$SRC/base/omniplay_host.py" "$SRC/base/omniplay_state.py" "$SRC/base/omniplay_host.rpy" "$base/"
  /bin/rm -f "$base/lib/$py"/iossupport.py[co]
  /bin/cp "$SRC/base/iossupport.py" "$base/lib/$py/iossupport.py"
  python3 - "$base/renpy" "$py" <<'PY'
# Ren'Py's distributor ships the engine without sources: Cython sources never, and Python modules as bytecode
# (Python 3: each __pycache__/<m>.cpython-3X.pyc moved up to <m>.pyc; Python 2: the .pyo files). A bundle is
# read-only, so a source file newer than its bytecode would be recompiled on every launch.
import os, sys
root, py = sys.argv[1], sys.argv[2]
tag = "cpython-" + py[len("python"):].replace(".", "")
for dirpath, dirnames, files in os.walk(root, topdown=False):
    for f in files:
        p = os.path.join(dirpath, f)
        if f.endswith((".pyx", ".pxd", ".pxi")):
            os.unlink(p)
        elif py.startswith("python3") and os.path.basename(dirpath) == "__pycache__" and f.endswith("." + tag + ".pyc"):
            os.replace(p, os.path.join(os.path.dirname(dirpath), f[: -len(tag) - 5] + ".pyc"))
        elif py.startswith("python3") and f.endswith(".py") and "renpy/common" not in p:
            os.unlink(p)
        elif py.startswith("python2") and f.endswith(".py") and os.path.exists(p + "o"):
            os.unlink(p)
    if os.path.basename(dirpath) == "__pycache__":
        for f in os.listdir(dirpath):
            os.unlink(os.path.join(dirpath, f))
        os.rmdir(dirpath)
PY
}


engine() {
  local v=$1 tag=${1//./} name="RenPy${1//./}" py=${python_line[$1]}
  unpack $v
  local stage="$WORK/stage-$tag" out="$OUT/$v"
  /bin/rm -rf "$stage" "$out"; mkdir -p "$stage" "$out"
  assemble_base $v "$stage/base"
  local frameworks=()
  for sdk in iphoneos iphonesimulator; do
    local target=arm64-apple-ios$IOS_MIN libs="$WORK/$v/renios/prototype/prebuilt/release" platform=iPhoneOS
    local mgl="$OUT/metalangle/MetalANGLE.xcframework/ios-arm64"
    if [[ $sdk == iphonesimulator ]]; then
      target=$target-simulator libs="$WORK/$v/renios/prototype/prebuilt/debug" platform=iPhoneSimulator
      mgl="$OUT/metalangle/MetalANGLE.xcframework/ios-arm64-simulator"
    fi
    local fw="$stage/$sdk/$name.framework" obj="$stage/$sdk/op_renpy.o"
    mkdir -p "$fw"
    echo "==> $name ($sdk)"
    xcrun --sdk $sdk clang -target $target -isysroot "$(sdk_path $sdk)" -O2 -fvisibility=hidden \
      -DOP_RENPY_VERSION="\"$v\"" -c "$SRC/op_renpy.c" -o "$obj"
    # SDL's GL lookup, relinked to ask MetalANGLE before anything else in the process (see opdls in op_renpy.c).
    # Given on the command line, this copy satisfies the symbols first and the archive's copy is never pulled.
    local gl="$stage/$sdk/SDL_uikitopengles.o"
    lipo "$libs/libSDL2.a" -thin arm64 -output "$stage/$sdk/libSDL2-arm64.a" 2>/dev/null || /bin/cp "$libs/libSDL2.a" "$stage/$sdk/libSDL2-arm64.a"
    (cd "$stage/$sdk" && ar -x libSDL2-arm64.a SDL_uikitopengles.o)
    python3 - "$gl" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
assert data.count(b"\0_dlsym\0") == 1, "expected one dlsym reference in SDL_uikitopengles.o"
open(sys.argv[1], "wb").write(data.replace(b"\0_dlsym\0", b"\0_opdls\0"))
PY
    local link=()
    for lib in $LINK_ORDER; do
      if [[ $lib == PYTHON ]]; then lib=$py; fi
      if [[ -f "$libs/lib$lib.a" ]]; then link+=(-l$lib); fi
    done
    for f in $FRAMEWORKS; do link+=(-framework $f); done
    for f in $WEAK_FRAMEWORKS; do link+=(-weak_framework $f); done
    xcrun --sdk $sdk clang -target $target -isysroot "$(sdk_path $sdk)" -dynamiclib \
      -install_name "@rpath/$name.framework/$name" -Wl,-rpath,@loader_path/.. \
      -Wl,-exported_symbols_list,"$SRC/exports.txt" -Wl,-dead_strip \
      -o "$fw/$name" "$obj" "$gl" -F"$mgl" -framework MetalANGLE -L"$libs" $link -lc++ -liconv
    python3 Scripts/native/rename-objc-classes.py "$fw/$name" "R${tag:0:2}"
    sed -e "s/@NAME@/$name/g" -e "s/@VERSION@/$v/g" -e "s/@TAG@/$tag/g" -e "s/@PLATFORM@/$platform/g" \
      -e "s/@MIN@/$IOS_MIN/g" "$SRC/Info.plist.in" >"$fw/Info.plist"
    /bin/cp -R "$stage/base" "$fw/base"
    # Sign the bundle, not the binary, so the signing identifier is CFBundleIdentifier (iOS refuses a mismatch).
    codesign -f -s - "$fw" 2>/dev/null
    frameworks+=(-framework "$fw")
  done
  xcodebuild -create-xcframework $frameworks -output "$out/$name.xcframework" >/dev/null
  Scripts/native/manifest.sh "renpy$tag" "Native/prebuilt/renpy/$v"
}

WANT=${1:-all}
if [[ $WANT == metalangle ]]; then metalangle; exit 0; fi
versions=(8.5.3 8.3.7 7.8.7)
if [[ $WANT != all ]]; then versions=($WANT); fi
for v in $versions; do [[ -n "${python_line[$v]:-}" ]] || { echo "unknown Ren'Py version $v (8.5.3, 8.3.7, 7.8.7)" >&2; exit 1; }; done
if ! Scripts/native/verify.sh metalangle >/dev/null 2>&1; then metalangle; fi
for v in $versions; do engine $v; done
echo "built $OUT"
