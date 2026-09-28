#!/bin/zsh
# Builds the embedded Godot engine: Native/prebuilt/godot/Godot.xcframework, one dylib framework per SDK, Godot's iOS
# platform (release template) with OmniPlay's host shim compiled in as a module (Native/godot/modules/omniplay,
# op_godot.h), exporting only op_godot_*.
#
# Sources:
#   Native/godot/src     submodule at the 4.7.2-stable tag
#
# Godot's iOS platform is a static library for Godot's own app template; the shim does what that app does at launch.
# Options that matter: disable_path_overrides=no (release templates refuse --main-pack otherwise), metal and opengl3 on
# the phone, opengl3 only on the simulator (Godot's build turns Metal and Vulkan off for it).
#
# Usage: build-godot.sh [--sdk iphoneos|iphonesimulator|all]  (default all)
source "$(dirname "$0")/common.sh"
cd "$NATIVE_ROOT"
require_xcode
require_tools scons python3
# SCons and Godot's build handle a path with spaces poorly; re-run through the space-free symlink.
if [[ "$NATIVE_ROOT" == *" "* && -z "${OMNIPLAY_NATIVE_LINKED:-}" ]]; then
  link="$HOME/.omniplay-native"
  [[ -L "$link" && "$(readlink "$link")" == "$NATIVE_ROOT" ]] || { /bin/rm -f "$link"; ln -s "$NATIVE_ROOT" "$link"; }
  OMNIPLAY_NATIVE_LINKED=1 exec zsh "$link/Scripts/native/build-godot.sh" "$@"
fi

SRC="$NATIVE_ROOT/Native/godot/src"
MODULES="$NATIVE_ROOT/Native/godot/modules"
WORK="$NATIVE_ROOT/Native/build/godot"
OUT="$NATIVE_ROOT/Native/prebuilt/godot"
[[ -f "$SRC/SConstruct" ]] || { echo "Native/godot/src is empty: git submodule update --init Native/godot/src" >&2; exit 1; }
FRAMEWORKS=(UIKit Foundation CoreFoundation AudioToolbox AVFoundation AVFAudio CoreAudio CoreMotion GameController
            QuartzCore OpenGLES CoreText CoreGraphics CoreVideo CoreMedia CoreHaptics UniformTypeIdentifiers Security
            SystemConfiguration MediaPlayer Photos AVKit SwiftUI)

build_sdk() {  # build_sdk <sdk>: $WORK/<sdk>/Godot.framework
  local sdk=$1 sysroot="$(sdk_path $1)" platform=iPhoneOS target=arm64-apple-ios$IOS_MIN swiftdir=iphoneos
  local flags=(metal=yes vulkan=no opengl3=yes) suffix=""
  if [[ $sdk == iphonesimulator ]]; then
    flags=(ios_simulator=yes metal=no vulkan=no opengl3=yes) suffix=.simulator
    platform=iPhoneSimulator target=$target-simulator swiftdir=iphonesimulator
  fi
  echo "==> Godot ($sdk)"
  mkdir -p "$WORK/$sdk"
  (cd "$SRC" && scons platform=ios arch=arm64 target=template_release disable_path_overrides=no \
    custom_modules="$MODULES" $flags -j$(sysctl -n hw.ncpu) >"$WORK/$sdk/scons.log" 2>&1) ||
    { grep -E "error:" "$WORK/$sdk/scons.log" | head -20 >&2 || true; echo "scons failed: $WORK/$sdk/scons.log" >&2; exit 1; }

  local fw="$WORK/$sdk/Godot.framework" lib="$SRC/bin/libgodot.ios.template_release.arm64$suffix.a"
  local camera="$SRC/bin/libgodot_camera.ios.template_release.arm64$suffix.a"
  local toolchain="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/$swiftdir"
  local links=() f
  for f in $FRAMEWORKS; do links+=(-framework $f); done
  [[ $sdk == iphoneos ]] && links+=(-framework Metal -framework MetalKit -framework MetalFX)  # no MetalFX in the simulator SDK
  /bin/rm -rf "$fw"; mkdir -p "$fw"
  # -ObjC keeps Godot's Objective-C classes the linker would otherwise drop; the Swift libraries are for Godot's
  # app template file, which the static library carries.
  xcrun --sdk $sdk clang++ -target $target -dynamiclib -o "$fw/Godot" -ObjC "$lib" "$camera" $links -lz \
    -L"$toolchain" -L"$sysroot/usr/lib/swift" -Wl,-rpath,/usr/lib/swift -install_name @rpath/Godot.framework/Godot \
    -Wl,-exported_symbols_list,"$NATIVE_ROOT/Native/godot/exports.txt" -Wl,-dead_strip ||
    { echo "link failed ($sdk)" >&2; exit 1; }
  xcrun strip -x "$fw/Godot"
  codesign -f -s - "$fw/Godot" 2>/dev/null
  sed -e "s/@NAME@/Godot/g" -e "s/@VERSION@/4.7.2/g" -e "s/@PLATFORM@/$platform/g" -e "s/@MIN@/$IOS_MIN/g" \
    -e "s/com.omniplay.engine.easyrpg/com.omniplay.engine.godot/" "$NATIVE_ROOT/Native/EasyRPG/Info.plist.in" >"$fw/Info.plist"
}

WANT=all
[[ "${1:-}" == "--sdk" ]] && WANT="$2"
sdks=(iphoneos iphonesimulator); [[ $WANT != all ]] && sdks=($WANT)
for sdk in $sdks; do build_sdk $sdk; done
if [[ $WANT == all ]]; then
  /bin/rm -rf "$OUT"; mkdir -p "$OUT"
  xcodebuild -create-xcframework -framework "$WORK/iphoneos/Godot.framework" \
    -framework "$WORK/iphonesimulator/Godot.framework" -output "$OUT/Godot.xcframework" >/dev/null
  Scripts/native/manifest.sh godot Native/prebuilt/godot Native/godot/src
fi
echo "built $OUT"
