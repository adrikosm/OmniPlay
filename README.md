# OmniPlay

OmniPlay is a personal-use, sideloaded iOS 27 game launcher and runtime host. It imports a game
distribution in a common container, identifies the engine and version, and runs it offline with a
matching embedded runtime: RPG Maker (MV/MZ through WebKit, XP/VX/VX Ace through mkxp-z, 2000/2003
through EasyRPG), Ren'Py, plain HTML5 titles and, as evidence allows, ScummVM, Godot and a few
smaller engines. Saves, controls, mods and diagnostics stay owned by the host. It runs what it can
identify and explains what it cannot; it does not claim universal compatibility.

**Status:** pre-alpha. Foundations are being laid; nothing plays a game yet.

## Requirements

- Apple silicon Mac with Xcode 27.0 (pinned in `.xcode-version`), the iOS 27 SDK and Swift 6.4
- iOS 27.0 simulator runtime (Xcode → Settings → Components)
- Homebrew, for xcodegen, ninja, meson, scons and pkg-config (`Scripts/bootstrap-mac.sh` installs them)
- A paid Apple Developer Program membership for device builds
- Reference device: iPhone 17 Pro Max on iOS 27

## Build and run

```bash
Scripts/bootstrap-mac.sh       # verify Xcode/Swift, install missing Homebrew tools, install git hooks
Scripts/build-libarchive.sh    # static libarchive + liblzma + libzstd XCFramework (device, simulator, Mac)
Scripts/generate-project.sh    # xcodegen: project.yml -> OmniPlay.xcodeproj
Scripts/build-sim.sh           # build, install and launch on the iPhone 17 Pro Max (iOS 27.0) simulator
Scripts/build-device.sh        # build, install and launch on the first paired iPhone
Scripts/test.sh                # swift test for every package, then the app test bundle on the simulator
```

Device builds read your team ID from `Signing.xcconfig`, which is gitignored. Copy
`Signing.xcconfig.example` and replace the placeholder. `OmniPlay.xcodeproj` is generated and
gitignored: edit `project.yml`, not the project.

## Repository layout

| Path | Contents |
|---|---|
| `App/` | SwiftUI shell on the UIScene lifecycle, Info.plist, entitlements, asset catalog |
| `Packages/` | Local SwiftPM packages holding all non-UI logic; none of them import SwiftUI |
| `Native/` | Pinned upstream sources as submodules (libarchive, xz, zstd, later the engines); build outputs are gitignored |
| `Scripts/` | Bootstrap, project generation, build, test and repository-hygiene scripts |
| `Fixtures/synthetic/` | Deterministic, generated test inputs with no game content (`Scripts/make-fixtures.py`) |
| `Fixtures/private/`, `Fixtures/large/` | Local-only real samples and multi-gigabyte stress inputs, gitignored |
| `Tests/` | App-level tests; each package carries its own test target |
| `Distribution/` | Sideload distribution metadata |
| `LICENSES/` | Full licence texts of third-party components |
| `project.yml` | xcodegen specification for the app target and package graph |

## Third-party components and licences

Every bundled component is listed in `THIRD-PARTY-LICENSES.txt` with its licence text under
`LICENSES/`. Patches applied to GPL/LGPL engines are published in this repository.

## What is deliberately not here

- Design documents and the roadmap: they live outside the repository, and `.gitignore` plus the
  pre-commit guard (`Scripts/check-public-safe.sh`) refuse any markdown other than this file.
- Fixtures containing real games, RTPs or soundfonts: only synthetic fixtures are committed.
- Signing configuration and provisioning profiles.
- Prebuilt binaries, DerivedData and the generated Xcode project: all reproducible from source.

## Legal

Users supply their own legally obtained games. OmniPlay includes no game content, no RTPs and no
DRM circumvention. It is development-signed and sideloaded for personal use; it is not distributed.
