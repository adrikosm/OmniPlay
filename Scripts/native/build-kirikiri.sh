#!/bin/zsh
# Builds KrKr2 Web, the KiriKiri 2/Z engine OmniPlay runs in its web view: Native/prebuilt/kirikiri/KrKr2Web/ (the
# engine page, JavaScript and WebAssembly), bundled as the app's KrKr2Web folder and served over each KiriKiri game.
#
# Sources:
#   Native/kirikiri/src                 submodule: retrom-project/kirikiroid2-web at 917a99e (krkr2's core as
#                                       WebAssembly, with Kirikiroid2's replacements for commercial games' plugins)
#   Native/patches/kirikiri/*.patch     OmniPlay's changes to the page: every game file read with Range requests
#                                       from a host manifest (?files=), saves kept by the host (?omniplay=1), and
#                                       VLFS.registerRemote, which the page calls but this revision lacks
#   Emscripten 4.0.23, vcpkg at b1e15efef675   the fork's own CI pins; fetched into Native/build/kirikiri
#
# Needs bison ≥ 3.8 (Homebrew), nasm, yasm, autoconf, automake, ninja, cmake. The first build compiles the vcpkg
# dependency tree (FFmpeg, OpenCV, Boost, cocos2d-x…) for wasm32-emscripten and takes a long time; vcpkg caches it.
#
# Usage: build-kirikiri.sh
source "$(dirname "$0")/common.sh"
cd "$NATIVE_ROOT"
require_tools cmake ninja git python3 nasm yasm autoconf automake
if [[ "$NATIVE_ROOT" == *" "* && -z "${OMNIPLAY_NATIVE_LINKED:-}" ]]; then
  link="$HOME/.omniplay-native"
  [[ -L "$link" && "$(readlink "$link")" == "$NATIVE_ROOT" ]] || { /bin/rm -f "$link"; ln -s "$NATIVE_ROOT" "$link"; }
  OMNIPLAY_NATIVE_LINKED=1 exec zsh "$link/Scripts/native/build-kirikiri.sh" "$@"
fi

SRC="$NATIVE_ROOT/Native/kirikiri/src"
# vcpkg's autotools ports (libtool) break on a path with spaces even through a symlink, so the work area lives
# on a real space-free path.
WORK="$HOME/.omniplay-build/krkr2web"
OUT="$NATIVE_ROOT/Native/prebuilt/kirikiri/KrKr2Web"
EMSDK_VERSION=4.0.23 VCPKG_COMMIT=b1e15efef6758eaa0beb0a8732cfa66f6a68a81d
[[ -f "$SRC/CMakeLists.txt" ]] || { echo "Native/kirikiri/src is empty: git submodule update --init --recursive Native/kirikiri/src" >&2; exit 1; }
BISON="$(brew --prefix bison 2>/dev/null)/bin"
[[ -x "$BISON/bison" ]] || { echo "bison 3.8+ missing: brew install bison" >&2; exit 1; }
mkdir -p "$WORK"

for patch in "$NATIVE_ROOT"/Native/patches/kirikiri/*.patch(N); do
  git -C "$SRC" apply --reverse --check "$patch" 2>/dev/null && continue
  git -C "$SRC" apply "$patch" || { echo "cannot apply ${patch:t} to Native/kirikiri/src" >&2; exit 1; }
done

[[ -d "$WORK/emsdk" ]] || git clone -q https://github.com/emscripten-core/emsdk.git "$WORK/emsdk"
"$WORK/emsdk/emsdk" install $EMSDK_VERSION >/dev/null && "$WORK/emsdk/emsdk" activate $EMSDK_VERSION >/dev/null
[[ -d "$WORK/vcpkg" ]] || git clone -q https://github.com/microsoft/vcpkg.git "$WORK/vcpkg"
if [[ "$(git -C "$WORK/vcpkg" rev-parse HEAD)" != $VCPKG_COMMIT ]]; then
  git -C "$WORK/vcpkg" fetch -q origin $VCPKG_COMMIT && git -C "$WORK/vcpkg" checkout -q $VCPKG_COMMIT
fi
[[ -x "$WORK/vcpkg/vcpkg" ]] || "$WORK/vcpkg/bootstrap-vcpkg.sh" -disableMetrics >/dev/null

echo "==> KrKr2 Web (configure and build; the first run builds the vcpkg tree)"
(
  source "$WORK/emsdk/emsdk_env.sh" >/dev/null 2>&1
  export VCPKG_ROOT="$WORK/vcpkg" PATH="$BISON:$PATH" VCPKG_DISABLE_METRICS=1
  cd "$SRC"
  cmake --preset "Web Release Config" -B "$WORK/out" >"$WORK/configure.log" 2>&1 ||
    { tail -30 "$WORK/configure.log" >&2; echo "configure failed: $WORK/configure.log" >&2; exit 1; }
  # Emscripten builds its ports on first use; parallel compile jobs then race for the port cache lock. Built
  # ahead, as the fork's CI does.
  embuilder build sdl2 sdl2_ttf sdl2-mt sdl2_ttf-mt >"$WORK/ports.log" 2>&1 ||
    { tail -20 "$WORK/ports.log" >&2; echo "embuilder failed: $WORK/ports.log" >&2; exit 1; }
  cmake --build "$WORK/out" -j$(sysctl -n hw.ncpu) >"$WORK/make.log" 2>&1 ||
    { grep -E "error" "$WORK/make.log" | head -20 >&2 || true; echo "build failed: $WORK/make.log" >&2; exit 1; }
) || exit 1

/bin/rm -rf "$OUT"; mkdir -p "$OUT"
# assets.zip carries the engine UI and its fallback font (DroidSansFallback, Apache 2.0).
for f in "$WORK/out"/index.{html,js,wasm,data,worker.js} "$WORK/out"/*.js(N) "$WORK/out"/assets.zip; do
  [[ -f "$f" ]] && /bin/cp -f "$f" "$OUT/"
done
[[ -f "$OUT/index.html" && -f "$OUT/index.wasm" ]] || { echo "build produced no index.html/index.wasm" >&2; exit 1; }
/bin/cp -f "$SRC/LICENSE" "$NATIVE_ROOT/LICENSES/kirikiri.txt"
Scripts/native/manifest.sh kirikiri Native/prebuilt/kirikiri Native/kirikiri/src
echo "built $OUT"
