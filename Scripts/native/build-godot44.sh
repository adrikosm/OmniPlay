#!/bin/zsh
# Builds the second Godot 4 engine: Native/prebuilt/godot44/Godot44.xcframework, for games exported with Godot 4.3 and
# 4.4 (their binary GDScript tokens are refused by 4.7). Same recipe as build-godot.sh with OmniPlay's 4.4 shim
# (Native/godot44/modules/omniplay, op_godot44.h, exporting only op_godot44_*), the patches in Native/patches/godot44,
# and every Objective-C class compiled with a GD44 prefix (Native/godot44/objc-renames.txt): 4.4 still uses generic
# names (AppDelegate, ViewController, GodotView), and the class table is process-wide.
#
# Sources:
#   Native/godot44/src   submodule at the 4.4.1-stable tag
#
# Godot's iOS platform is a static library for Godot's own app template; the shim does what that app does at launch.
# Options that matter: disable_path_overrides=no (release templates refuse --main-pack otherwise), metal and opengl3 on
# the phone, opengl3 only on the simulator (Godot's build turns Metal and Vulkan off for it).
#
# Usage: build-godot44.sh [--sdk iphoneos|iphonesimulator|all]  (default all)
source "$(dirname "$0")/common.sh"
cd "$NATIVE_ROOT"
require_xcode
require_tools scons python3
# SCons and Godot's build handle a path with spaces poorly; re-run through the space-free symlink.
relink_without_spaces "${0:t}" "$@"

SRC="$NATIVE_ROOT/Native/godot44/src"
MODULES="$NATIVE_ROOT/Native/godot44/modules"
WORK="$NATIVE_ROOT/Native/build/godot44"
OUT="$NATIVE_ROOT/Native/prebuilt/godot44"
[[ -f "$SRC/SConstruct" ]] || { echo "Native/godot44/src is empty: git submodule update --init Native/godot44/src" >&2; exit 1; }
apply_patches "$SRC" "$NATIVE_ROOT/Native/patches/godot44"
RENAMES="$(cat "$NATIVE_ROOT/Native/godot44/objc-renames.txt")"
FRAMEWORKS=(UIKit Foundation CoreFoundation AudioToolbox AVFoundation AVFAudio CoreAudio CoreMotion GameController
            QuartzCore OpenGLES CoreText CoreGraphics CoreVideo CoreMedia CoreHaptics UniformTypeIdentifiers Security
            SystemConfiguration MediaPlayer Photos AVKit SwiftUI)

build_sdk() {  # build_sdk <sdk>: $WORK/<sdk>/Godot44.framework
  local sdk=$1 sysroot="$(sdk_path $1)" platform=iPhoneOS target=arm64-apple-ios$IOS_MIN swiftdir=iphoneos
  local flags=(metal=yes vulkan=no opengl3=yes) suffix=""
  if [[ $sdk == iphonesimulator ]]; then
    flags=(ios_simulator=yes metal=no vulkan=no opengl3=yes) suffix=.simulator
    platform=iPhoneSimulator target=$target-simulator swiftdir=iphonesimulator
  fi
  echo "==> Godot 4.4 ($sdk)"
  mkdir -p "$WORK/$sdk"
  (cd "$SRC" && scons platform=ios arch=arm64 target=template_release disable_path_overrides=no \
    custom_modules="$MODULES" "ccflags=$RENAMES" $flags -j$(sysctl -n hw.ncpu) >"$WORK/$sdk/scons.log" 2>&1) ||
    { grep -E "error:" "$WORK/$sdk/scons.log" | head -20 >&2 || true; echo "scons failed: $WORK/$sdk/scons.log" >&2; exit 1; }

  local fw="$WORK/$sdk/Godot44.framework" lib="$SRC/bin/libgodot.ios.template_release.arm64$suffix.a"
  local camera="$SRC/bin/libgodot_camera.ios.template_release.arm64$suffix.a"
  local toolchain="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/$swiftdir"
  local links=() f extra=()
  [[ -f "$camera" ]] && extra=("$camera")
  for f in $FRAMEWORKS; do links+=(-framework $f); done
  [[ $sdk == iphoneos ]] && links+=(-framework Metal -framework MetalKit -framework MetalFX)  # no MetalFX in the simulator SDK
  /bin/rm -rf "$fw"; mkdir -p "$fw"
  # -ObjC keeps Godot's Objective-C classes the linker would otherwise drop; the Swift libraries are for Godot's
  # app template file, which the static library carries.
  xcrun --sdk $sdk clang++ -target $target -dynamiclib -o "$fw/Godot44" -ObjC "$lib" $extra $links -lz \
    -L"$toolchain" -L"$sysroot/usr/lib/swift" -Wl,-rpath,/usr/lib/swift -install_name @rpath/Godot44.framework/Godot44 \
    -Wl,-exported_symbols_list,"$NATIVE_ROOT/Native/godot44/exports.txt" -Wl,-dead_strip ||
    { echo "link failed ($sdk)" >&2; exit 1; }
  xcrun strip -x "$fw/Godot44"
  sed -e "s/@NAME@/Godot44/g" -e "s/@VERSION@/4.4.1/g" -e "s/@PLATFORM@/$platform/g" -e "s/@MIN@/$IOS_MIN/g" \
    -e "s/com.omniplay.engine.easyrpg/com.omniplay.engine.godot44/" "$NATIVE_ROOT/Native/EasyRPG/Info.plist.in" >"$fw/Info.plist"
  # Sign the bundle, not the binary, so the signing identifier is CFBundleIdentifier (iOS refuses a mismatch).
  codesign -f -s - "$fw" 2>/dev/null
}

WANT=all
[[ "${1:-}" == "--sdk" ]] && WANT="$2"
sdks=(iphoneos iphonesimulator); [[ $WANT != all ]] && sdks=($WANT)
for sdk in $sdks; do build_sdk $sdk; done
if [[ $WANT == all ]]; then
  /bin/rm -rf "$OUT"; mkdir -p "$OUT"
  xcodebuild -create-xcframework -framework "$WORK/iphoneos/Godot44.framework" \
    -framework "$WORK/iphonesimulator/Godot44.framework" -output "$OUT/Godot44.xcframework" >/dev/null
  Scripts/native/manifest.sh godot44 Native/prebuilt/godot44 Native/godot44/src
fi
echo "built $OUT"
