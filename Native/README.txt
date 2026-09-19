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
