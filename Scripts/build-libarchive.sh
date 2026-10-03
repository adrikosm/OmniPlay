#!/bin/zsh
# Builds liblzma (xz), libzstd and libarchive as static libraries for iphoneos, iphonesimulator and macosx
# (all arm64) and merges them into Packages/GameImport/Native/libarchive.xcframework with a module map.
# zlib, bzip2 and iconv come from the Apple SDKs. Everything under Native/build and the xcframework is gitignored.
source "$(dirname "$0")/native/common.sh"
cd "$NATIVE_ROOT"
ROOT="$PWD"; BUILD="$ROOT/Native/build"; OUT="$ROOT/Packages/GameImport/Native"
require_tools cmake ninja
for sub in libarchive xz zstd/build/cmake; do [[ -f "$ROOT/Native/$sub/CMakeLists.txt" ]] || { echo "Native/$sub is empty: git submodule update --init" >&2; exit 1; }; done

# platform  cmake-system  sdk-name          deployment-flag
targets=(
  "iphoneos        iOS     iphoneos         -DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_MIN"
  "iphonesimulator iOS     iphonesimulator  -DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_MIN"
  "macosx          Darwin  macosx           -DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOS_MIN"
)
libs=()
for t in $targets; do
  read -r plat sysname sdk deploy <<< "$t"
  sysroot="$(sdk_path $sdk)"
  prefix="$BUILD/$plat/install"
  common=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME=$sysname -DCMAKE_OSX_SYSROOT="$sysroot"
          -DCMAKE_OSX_ARCHITECTURES=arm64 $deploy -DCMAKE_INSTALL_PREFIX="$prefix" -DBUILD_SHARED_LIBS=OFF
          -DCMAKE_FIND_ROOT_PATH="$prefix" -DCMAKE_POSITION_INDEPENDENT_CODE=ON)
  [[ $sysname == iOS ]] && common+=(-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER)
  echo "==> xz ($plat)"
  cmake -S Native/xz -B "$BUILD/$plat/xz" "${common[@]}" -DXZ_TOOL_XZ=OFF -DXZ_TOOL_XZDEC=OFF -DXZ_TOOL_LZMADEC=OFF \
        -DXZ_TOOL_LZMAINFO=OFF -DXZ_TOOL_SCRIPTS=OFF -DXZ_DOC=OFF -DXZ_NLS=OFF -DXZ_THREADS=posix >/dev/null
  cmake --build "$BUILD/$plat/xz" --target install >/dev/null
  echo "==> zstd ($plat)"
  cmake -S Native/zstd/build/cmake -B "$BUILD/$plat/zstd" "${common[@]}" -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_SHARED=OFF \
        -DZSTD_BUILD_STATIC=ON -DZSTD_BUILD_TESTS=OFF -DZSTD_LEGACY_SUPPORT=OFF -DZSTD_MULTITHREAD_SUPPORT=OFF >/dev/null
  cmake --build "$BUILD/$plat/zstd" --target install >/dev/null
  echo "==> libarchive ($plat)"
  cmake -S Native/libarchive -B "$BUILD/$plat/libarchive" "${common[@]}" \
        -DENABLE_ZLIB=ON -DENABLE_BZip2=ON -DENABLE_LZMA=ON -DENABLE_ZSTD=ON -DENABLE_ICONV=ON \
        -DENABLE_OPENSSL=OFF -DENABLE_LIBB2=OFF -DENABLE_LZ4=OFF -DENABLE_LZO=OFF -DENABLE_LIBXML2=OFF -DENABLE_EXPAT=OFF \
        -DENABLE_PCREPOSIX=OFF -DENABLE_PCRE2POSIX=OFF -DENABLE_LIBGCC=OFF -DENABLE_CNG=OFF -DENABLE_MBEDTLS=OFF -DENABLE_NETTLE=OFF \
        -DENABLE_TAR=OFF -DENABLE_CPIO=OFF -DENABLE_CAT=OFF -DENABLE_UNZIP=OFF -DENABLE_TEST=OFF -DENABLE_INSTALL=ON \
        -DENABLE_ACL=OFF -DENABLE_XATTR=OFF -DENABLE_WERROR=OFF \
        -DLIBLZMA_INCLUDE_DIR="$prefix/include" -DLIBLZMA_LIBRARY="$prefix/lib/liblzma.a" \
        -DZSTD_INCLUDE_DIR="$prefix/include" -DZSTD_LIBRARY="$prefix/lib/libzstd.a" >/dev/null
  cmake --build "$BUILD/$plat/libarchive" --target install >/dev/null
  echo "==> merge ($plat)"
  libtool -static -o "$BUILD/$plat/libarchive_all.a" "$prefix/lib/libarchive.a" "$prefix/lib/liblzma.a" "$prefix/lib/libzstd.a"
  mkdir -p "$BUILD/$plat/headers"
  cp "$prefix/include/archive.h" "$prefix/include/archive_entry.h" "$BUILD/$plat/headers/"
  cat > "$BUILD/$plat/headers/module.modulemap" <<'MM'
module CLibArchive {
    header "archive.h"
    header "archive_entry.h"
    export *
}
MM
  libs+=(-library "$BUILD/$plat/libarchive_all.a" -headers "$BUILD/$plat/headers")
done
mkdir -p "$OUT"; /bin/rm -rf "$OUT/libarchive.xcframework"
xcodebuild -create-xcframework "${libs[@]}" -output "$OUT/libarchive.xcframework" >/dev/null
echo "built $OUT/libarchive.xcframework"
Scripts/native/manifest.sh libarchive Packages/GameImport/Native/libarchive.xcframework Native/libarchive Native/xz Native/zstd
