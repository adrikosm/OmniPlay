#!/bin/zsh
# Builds the embedded Godot 3 engine: Native/prebuilt/godot3/Godot3.xcframework, one dylib framework per SDK, Godot
# 3's iOS platform (release export template, GLES) with OmniPlay's host shim compiled in as a module
# (Native/godot3/modules/omniplay, op_godot3.h), exporting only op_godot3_*.
#
# Sources:
#   Native/godot3/src    submodule at the 3.6.3-stable tag
#
# Godot 3's Objective-C classes have generic names (AppDelegate, ViewController, GodotView, ...) and the Objective-C
# class table is process-wide, so every one is compiled with a GD3 prefix (Native/godot3/objc-renames.txt).
#
# Usage: build-godot3.sh [--sdk iphoneos|iphonesimulator|all]  (default all)
source "$(dirname "$0")/common.sh"
cd "$NATIVE_ROOT"
require_xcode
require_tools scons python3
relink_without_spaces "${0:t}" "$@"

SRC="$NATIVE_ROOT/Native/godot3/src"
WORK="$NATIVE_ROOT/Native/build/godot3"
OUT="$NATIVE_ROOT/Native/prebuilt/godot3"
[[ -f "$SRC/SConstruct" ]] || { echo "Native/godot3/src is empty: git submodule update --init Native/godot3/src" >&2; exit 1; }
RENAMES="$(cat "$NATIVE_ROOT/Native/godot3/objc-renames.txt")"
FRAMEWORKS=(UIKit Foundation CoreFoundation AudioToolbox AVFoundation CoreAudio CoreMotion GameController QuartzCore
            OpenGLES CoreText CoreGraphics CoreVideo CoreMedia CoreHaptics Security SystemConfiguration MediaPlayer
            Photos AVKit StoreKit)

build_sdk() {  # build_sdk <sdk>: $WORK/<sdk>/Godot3.framework
  local sdk=$1 platform=iPhoneOS target=arm64-apple-ios$IOS_MIN flags=() suffix=""
  [[ $sdk == iphonesimulator ]] && flags=(ios_simulator=yes) suffix=.simulator platform=iPhoneSimulator target=$target-simulator
  echo "==> Godot 3 ($sdk)"
  mkdir -p "$WORK/$sdk"
  (cd "$SRC" && scons platform=iphone arch=arm64 target=release tools=no custom_modules="$NATIVE_ROOT/Native/godot3/modules" \
    "CCFLAGS=$RENAMES" $flags -j$(sysctl -n hw.ncpu) >"$WORK/$sdk/scons.log" 2>&1) ||
    { grep -E "error:" "$WORK/$sdk/scons.log" | head -20 >&2 || true; echo "scons failed: $WORK/$sdk/scons.log" >&2; exit 1; }
  local fw="$WORK/$sdk/Godot3.framework" links=() f
  for f in $FRAMEWORKS; do links+=(-framework $f); done
  /bin/rm -rf "$fw"; mkdir -p "$fw"
  xcrun --sdk $sdk clang++ -target $target -dynamiclib -o "$fw/Godot3" -ObjC "$SRC/bin/libgodot.iphone.opt.arm64$suffix.a" \
    $links -lz -install_name @rpath/Godot3.framework/Godot3 \
    -Wl,-exported_symbols_list,"$NATIVE_ROOT/Native/godot3/exports.txt" -Wl,-dead_strip || { echo "link failed ($sdk)" >&2; exit 1; }
  [[ -n "${OMNIPLAY_KEEP_SYMBOLS:-}" ]] || xcrun strip -x "$fw/Godot3"
  sed -e "s/@NAME@/Godot3/g" -e "s/@VERSION@/3.6.3/g" -e "s/@PLATFORM@/$platform/g" -e "s/@MIN@/$IOS_MIN/g" \
    -e "s/com.omniplay.engine.easyrpg/com.omniplay.engine.godot3/" "$NATIVE_ROOT/Native/EasyRPG/Info.plist.in" >"$fw/Info.plist"
  # Sign the bundle, not the binary, so the signing identifier is CFBundleIdentifier (iOS refuses a mismatch).
  codesign -f -s - "$fw" 2>/dev/null
}

WANT=all
[[ "${1:-}" == "--sdk" ]] && WANT="$2"
sdks=(iphoneos iphonesimulator); [[ $WANT != all ]] && sdks=($WANT)
for sdk in $sdks; do build_sdk $sdk; done
if [[ $WANT == all ]]; then
  /bin/rm -rf "$OUT"; mkdir -p "$OUT"
  xcodebuild -create-xcframework -framework "$WORK/iphoneos/Godot3.framework" \
    -framework "$WORK/iphonesimulator/Godot3.framework" -output "$OUT/Godot3.xcframework" >/dev/null
  Scripts/native/manifest.sh godot3 Native/prebuilt/godot3 Native/godot3/src
fi
echo "built $OUT"
