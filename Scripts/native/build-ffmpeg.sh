#!/bin/zsh
# FFmpeg for OmniPlay's media preparation: every video and audio format a game might ship, decoded on the phone and
# converted to one its engine plays. LGPL build (no --enable-gpl, no nonfree), static, arm64, device and simulator.
#
#   decoders, demuxers, parsers   all of FFmpeg's own (the point: read anything), plus dav1d for AV1: FFmpeg's own
#                                 AV1 decoder only drives hardware
#   encoders                      h264_videotoolbox + aac (MP4 for WebKit), libtheora + libvorbis (Ogg for mkxp-z and
#                                 Ren'Py, whose own decoders read Theora and Vorbis), pcm_s16le, mjpeg
#   muxers                        mp4, mov, ogg, wav        protocols: file only; no network, devices or filters
#
# libtheora/libvorbis/libogg are the ones mkxp-z's dependency release already puts in the app (BSD); FFmpeg links
# against the same static libraries, so nothing is duplicated. Output:
#   Native/prebuilt/ffmpeg/include                       public headers (identical for both SDKs)
#   Native/prebuilt/ffmpeg/<iphoneos|iphonesimulator>/lib  libavformat, libavcodec, libswscale, libswresample, libavutil
#
# Usage: build-ffmpeg.sh
source "$(dirname "$0")/common.sh"
cd "$NATIVE_ROOT"
# FFmpeg's configure refuses a source path with spaces; run through the same space-free link build-mkxpz.sh uses.
relink_without_spaces "${0:t}" "$@"
require_xcode
require_tools curl make meson ninja

VERSION=9.0.1
SHA=cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635
WORK="$NATIVE_ROOT/Native/build/ffmpeg"
OUT="$NATIVE_ROOT/Native/prebuilt/ffmpeg"

file="$WORK/downloads/ffmpeg-$VERSION.tar.xz"
fetch_pinned "$file" "$SHA" "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
SRC="$WORK/ffmpeg-$VERSION"
[[ -d "$SRC" ]] || tar xJf "$file" -C "$WORK"

DAV1D_VERSION=1.5.4
DAV1D_SHA=686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5  # as VideoLAN publishes it
dav1d_file="$WORK/downloads/dav1d-$DAV1D_VERSION.tar.xz"
fetch_pinned "$dav1d_file" "$DAV1D_SHA" "https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.xz"
DAV1D_SRC="$WORK/dav1d-$DAV1D_VERSION"
[[ -d "$DAV1D_SRC" ]] || tar xJf "$dav1d_file" -C "$WORK"

build_dav1d() {  # build_dav1d <sdk> <target> <prefix>: static libdav1d, 8- and 16-bit, NEON on
  local sdk=$1 target=$2 prefix=$3 cross="$WORK/dav1d-$1.cross" build="$WORK/dav1d-build-$1"
  local sysroot; sysroot="$(sdk_path $sdk)"
  cat >"$cross" <<CROSS
[binaries]
c = ['$(xcrun --sdk $sdk -f clang)', '-target', '$target', '-isysroot', '$sysroot']
ar = '$(xcrun --sdk $sdk -f ar)'
strip = '$(xcrun --sdk $sdk -f strip)'
[host_machine]
system = 'darwin'
subsystem = 'ios'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
CROSS
  /bin/rm -rf "$build" "$prefix"
  meson setup "$build" "$DAV1D_SRC" --cross-file "$cross" --prefix "$prefix" --libdir lib --buildtype release \
    -Ddefault_library=static -Denable_tools=false -Denable_tests=false -Denable_docs=false >"$WORK/dav1d-$sdk.log" 2>&1 \
    || { tail -30 "$WORK/dav1d-$sdk.log" >&2; exit 1; }
  ninja -C "$build" install >>"$WORK/dav1d-$sdk.log" 2>&1 || { tail -30 "$WORK/dav1d-$sdk.log" >&2; exit 1; }
}

/bin/rm -rf "$OUT"; mkdir -p "$OUT"
for sdk in iphoneos iphonesimulator; do
  deps="$NATIVE_ROOT/Native/prebuilt/mkxp-z/$sdk-arm64/deps"
  [[ -f "$deps/lib/libtheoraenc.a" ]] || { echo "mkxp-z dependencies missing for $sdk: run Scripts/native/hydrate.sh" >&2; exit 1; }
  target="arm64-apple-ios$IOS_MIN"
  [[ $sdk == iphonesimulator ]] && target="$target-simulator"
  # Our own pkg-config files: the release's point at the machine that built it.
  pc="$WORK/pkgconfig-$sdk"; /bin/rm -rf "$pc"; mkdir -p "$pc"
  for spec in "ogg::-logg" "vorbis:ogg:-lvorbis" "vorbisenc:vorbis:-lvorbisenc" "theoradec:ogg:-ltheoradec" "theoraenc:theoradec:-ltheoraenc"; do
    name=${spec%%:*}; rest=${spec#*:}; requires=${rest%%:*}; libs=${rest#*:}
    printf 'prefix=%s\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\nName: %s\nDescription: %s\nVersion: 1.3.7\nRequires: %s\nLibs: -L${libdir} %s\nCflags: -I${includedir}\n' \
      "$deps" "$name" "$name" "$requires" "$libs" >"$pc/$name.pc"
  done
  echo "==> dav1d $DAV1D_VERSION ($sdk)"
  dav1d="$WORK/dav1d-$sdk"
  build_dav1d $sdk $target "$dav1d"
  /bin/cp -f "$dav1d/lib/pkgconfig/dav1d.pc" "$pc/"
  build="$WORK/build-$sdk"; stage="$WORK/stage-$sdk"
  /bin/rm -rf "$build" "$stage"; mkdir -p "$build"
  echo "==> FFmpeg $VERSION ($sdk)"
  (
    cd "$build"
    PKG_CONFIG_LIBDIR="$pc" "$SRC/configure" --prefix="$stage" \
      --enable-cross-compile --target-os=darwin --arch=aarch64 \
      --cc="$(xcrun --sdk $sdk -f clang)" --sysroot="$(sdk_path $sdk)" \
      --extra-cflags="-target $target" --extra-ldflags="-target $target" --pkg-config=pkg-config \
      --enable-static --disable-shared --enable-pic --disable-debug --disable-doc --disable-programs \
      --disable-autodetect --enable-videotoolbox --enable-audiotoolbox --enable-zlib --enable-bzlib \
      --disable-network --disable-avdevice --disable-avfilter \
      --disable-protocols --enable-protocol=file \
      --disable-muxers --enable-muxer=mp4,mov,ogg,wav \
      --disable-encoders --enable-encoder=h264_videotoolbox,aac,libtheora,libvorbis,pcm_s16le,mjpeg \
      --enable-libtheora --enable-libvorbis --enable-libdav1d >configure.log 2>&1 || { tail -30 configure.log >&2; exit 1; }
    make -j"$(sysctl -n hw.ncpu)" >make.log 2>&1 || { tail -40 make.log >&2; exit 1; }
    make install >install.log 2>&1
  )
  mkdir -p "$OUT/$sdk/lib"
  /bin/cp -f "$stage"/lib/lib{avformat,avcodec,swscale,swresample,avutil}.a "$dav1d/lib/libdav1d.a" "$OUT/$sdk/lib/"
  [[ -d "$OUT/include" ]] || /bin/cp -R "$stage/include" "$OUT/include"
done
Scripts/native/manifest.sh ffmpeg Native/prebuilt/ffmpeg
echo "built $OUT"
