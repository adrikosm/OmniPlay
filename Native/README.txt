Native artefacts: how they are built, pinned, cached and verified
=================================================================

Layout
  Native/<lib>/                 pinned source (git submodule, exact tag or commit)
  Native/build/<platform>/      scratch build trees (ignored)
  Native/manifests/<comp>.json  committed manifest for one built component
  Packages/<Pkg>/Native/*.xcframework
                                the artefact a Swift package links (ignored, reproducible)

Manifest (one per component, written by Scripts/native/manifest.sh)
  component, built_at, toolchain (xcodebuild -version), sdks (iphoneos/iphonesimulator/macosx versions),
  arch (arm64 only), flags (deployment targets), sources { submodule path: commit }, outputs { relative path: sha256 }.

Scripts (Scripts/native/)
  common.sh    SDK roots, deployment targets (iOS 27.0, macOS 15.0), arm64 only; sourced by every build script.
  manifest.sh  <component> <artefact dir> <submodule...>  writes Native/manifests/<component>.json.
  verify.sh    [component]  recomputes hashes of every listed output and fails on a missing or changed file.
  hydrate.sh   [component]  makes artefacts present and valid: restore from $OMNIPLAY_NATIVE_CACHE/<component>/
               when the cached copy verifies, otherwise run the component's build script; then verify.
               Runs as the "Hydrate native deps" pre-build phase, so a clean clone builds after bootstrap-mac.sh.

Rules
  * Pinned sources only; bumping a submodule means rebuilding and committing the new manifest in the same change.
  * Nothing prebuilt is committed. A local cache directory is optional and never trusted without verification.
  * Every component adds its licence to THIRD-PARTY-LICENSES.txt and LICENSES/<component>.txt.
  * Missing tools fail early with the bootstrap-mac.sh instruction; a wrong Xcode fails in common.sh.

Components
  libarchive   Scripts/build-libarchive.sh  → Packages/GameImport/Native/libarchive.xcframework
               (libarchive 3.8.9 + xz 5.8.4 + zstd 1.5.7; zlib, bzip2 and iconv from the Apple SDKs)
  mkxp-z       Scripts/native/build-mkxpz.sh  → Native/prebuilt/mkxp-z/<sdk>-arm64/
               (mateo-m/mkxp-z-apple-mobile, tag engine-2026-09-11; the fork's tools compile the core and the three
               Ruby bindings; its pinned dependency release is fetched by the fork's own script and copied beside them)
  rgss-assets  Scripts/native/assemble-rgss-assets.sh → Native/prebuilt/rgss-assets/ (shaders, fonts, preload and
               postload Ruby, gamecontrollerdb, CA bundle, Ruby stdlib subsets; bundled as the RGSSAssets folder)
  unrar        Scripts/build-unrar.sh → Packages/GameImport/Native/unrar.xcframework
               (UnRAR 7.2.7, decoder only; callback C bridge under Packages/GameImport/Sources/CUnrar)
  metalangle   Scripts/native/build-renpy.sh metalangle → Native/prebuilt/renpy/metalangle/MetalANGLE.xcframework
               (arm64 slices of the MetalANGLE dylib from Ren'Py's 8.5.3 iOS package; shared by the three engines)
  renpy853     Scripts/native/build-renpy.sh 8.5.3 → Native/prebuilt/renpy/8.5.3/RenPy853.xcframework
  renpy837     Scripts/native/build-renpy.sh 8.3.7 → Native/prebuilt/renpy/8.3.7/RenPy837.xcframework
  renpy787     Scripts/native/build-renpy.sh 7.8.7 → Native/prebuilt/renpy/7.8.7/RenPy787.xcframework
               (one dylib framework per engine: Ren'Py's own renios static libraries and SDK engine tree, pinned by
               sha256, linked behind Native/RenPy/op_renpy.h with the host glue from Native/RenPy/base; embedded,
               not linked, and opened by RenPyEngineLibrary on first use)
  easyrpg      Scripts/native/build-easyrpg.sh → Native/prebuilt/easyrpg/EasyRPG.xcframework
               (EasyRPG Player 0.8.1.1 + liblcf 0.8.1 submodules, fmt/inih/mpg123/speexdsp tarballs pinned by sha256,
               SDL2 and codecs from the mkxp-z tree, the system ICU; one dylib framework per SDK behind
               Native/EasyRPG/op_easyrpg.h, embedded like the Ren'Py engines)
