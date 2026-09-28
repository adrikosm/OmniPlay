#!/bin/zsh
# MIDI for RPG Maker XP and VX: FluidSynth and a General MIDI soundfont.
#
# mkxp-z synthesises MIDI through FluidSynth, which it opens at run time as @rpath/libfluidsynth.dylib; without it the
# engine logs "Midi playback is disabled" and XP/VX music (MIDI, like their RTPs) is silent. This builds FluidSynth
# as that dylib for device and simulator (LGPL-2.1, kept a separate image), and fetches GeneralUser GS, the default
# soundfont (free to use and redistribute; see its LICENSE). Both are pinned by sha256.
#
#   Native/prebuilt/fluidsynth/libfluidsynth.xcframework   embedded in the app, not linked
#   Native/prebuilt/soundfont/GeneralUser-GS.sf2           app resource
#
# FluidSynth is configured for what mkxp-z uses: fluid_synth_write_s16 into the engine's own OpenAL stream. No audio or
# MIDI drivers, no glib (OS layer: C++11), no libsndfile (so .sf2 only, not .sf3), no network, no OpenMP.
#
# Usage: build-fluidsynth.sh
source "$(dirname "$0")/common.sh"
cd "$NATIVE_ROOT"
require_xcode
require_tools cmake ninja curl

FS_VERSION=2.6.1
FS_SHA=3d258a3bf97cc20c59eeebfe62c2432fae88adda74d3ad098681c76e0ebf446b
GU_COMMIT=684543d5e5efaef08d02be50dcda8d552478fa60
GU_SHA=9575028c7a1f589f5770fccc8cff2734566af40cd26ed836944e9a5152688cfe
GU_LICENSE_SHA=7b32efefdf95ce38a043799f0659853ddc00fbaa14d8c50f0aca16b9b8b405be

WORK="$NATIVE_ROOT/Native/build/fluidsynth"
OUT="$NATIVE_ROOT/Native/prebuilt/fluidsynth"
SF_OUT="$NATIVE_ROOT/Native/prebuilt/soundfont"

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

fetch "fluidsynth-$FS_VERSION.tar.gz" $FS_SHA "https://github.com/FluidSynth/fluidsynth/archive/refs/tags/v$FS_VERSION.tar.gz"
fetch GeneralUser-GS.sf2 $GU_SHA "https://raw.githubusercontent.com/mrbumpy409/GeneralUser-GS/$GU_COMMIT/GeneralUser-GS.sf2"
fetch GeneralUser-GS-LICENSE.txt $GU_LICENSE_SHA "https://raw.githubusercontent.com/mrbumpy409/GeneralUser-GS/$GU_COMMIT/documentation/LICENSE.txt"

SRC="$WORK/fluidsynth-$FS_VERSION"
[[ -d "$SRC" ]] || tar xzf "$WORK/downloads/fluidsynth-$FS_VERSION.tar.gz" -C "$WORK"

OFF=(alsa aufile dbus ipv6 jack ladspa libsndfile midishare opensles oboe network oss dsound wasapi waveout winmidi sdl3
     pulseaudio pipewire readline openmp systemd coreaudio coremidi framework signalsmith profiling coverage)
flags=()
for o in $OFF; do flags+=(-Denable-$o=OFF); done

/bin/rm -rf "$OUT"; mkdir -p "$OUT"
libraries=()
for sdk in iphoneos iphonesimulator; do
  build="$WORK/build-$sdk"
  /bin/rm -rf "$build"
  echo "==> FluidSynth $FS_VERSION ($sdk)"
  cmake -S "$SRC" -B "$build" -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=$sdk -DCMAKE_OSX_ARCHITECTURES=$ARCH \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_MIN -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_INSTALL_NAME_DIR=@rpath -DCMAKE_MACOSX_BUNDLE=OFF -Dosal=cpp11 -Denable-threads=ON -Denable-native-dls=ON $flags >/dev/null
  cmake --build "$build" --target libfluidsynth >/dev/null
  local_lib=$(find "$build" -name "libfluidsynth.*.dylib" -type f | head -1)
  mkdir -p "$WORK/stage-$sdk"
  lib="$WORK/stage-$sdk/libfluidsynth.dylib"
  /bin/cp -f "$local_lib" "$lib"
  # The engine asks for exactly @rpath/libfluidsynth.dylib.
  install_name_tool -id @rpath/libfluidsynth.dylib "$lib"
  codesign -f -s - "$lib" 2>/dev/null
  libraries+=(-library "$lib")
done
xcodebuild -create-xcframework $libraries -output "$OUT/libfluidsynth.xcframework" >/dev/null
Scripts/native/manifest.sh fluidsynth Native/prebuilt/fluidsynth

/bin/rm -rf "$SF_OUT"; mkdir -p "$SF_OUT"
/bin/cp -f "$WORK/downloads/GeneralUser-GS.sf2" "$SF_OUT/"
Scripts/native/manifest.sh soundfont Native/prebuilt/soundfont
echo "built $OUT and $SF_OUT"
