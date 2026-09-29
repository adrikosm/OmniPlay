# OmniPlay

OmniPlay is a personal-use, sideloaded iOS 27 game launcher and runtime host. It imports a game
distribution in a common container, identifies the engine and version, and runs it offline with a
matching embedded runtime: RPG Maker (MV/MZ through WebKit, XP/VX/VX Ace through mkxp-z, 2000/2003
through EasyRPG), Ren'Py, plain HTML5 titles ScummVM, Godot, Wolf RPG, KiriKiri and TyranoBuilder. These are MVP targets; runtime
availability is still being implemented. Unity/Unite is best-effort coverage. Saves, controls, mods and diagnostics stay owned by the host. It runs what it can
identify and explains what it cannot; it does not claim universal compatibility.

**Status:** pre-alpha. The web slice has simulator acceptance, RGSS integration is in progress, and the
three Ren'Py engines (8.5.3, 8.3.7, 7.8.7) play imported games on the simulator. Other required native
runtimes are not yet available. Physical-device compatibility remains unverified.

## Requirements

- Apple silicon Mac with Xcode 27.0 (pinned in `.xcode-version`), the iOS 27 SDK and Swift 6.4
- iOS 27.0 simulator runtime (Xcode → Settings → Components)
- Homebrew, for xcodegen, ninja, meson, scons and pkg-config (`Scripts/bootstrap-mac.sh` installs them)
- Your own signing team/profile for installation; unsigned preparation needs no Apple account
- Reference device: iPhone 17 Pro Max on iOS 27

## Build and run

```bash
Scripts/bootstrap-mac.sh       # verify Xcode/Swift, install missing Homebrew tools
Scripts/build-libarchive.sh    # static libarchive + liblzma + libzstd XCFramework (device, simulator, Mac)
Scripts/native/build-renpy.sh  # the three Ren'Py engine frameworks from Ren'Py's own iOS packages (~800 MB download)
Scripts/generate-project.sh    # xcodegen: project.yml -> OmniPlay.xcodeproj
Scripts/build-sim.sh           # build, install and launch on the iPhone 17 Pro Max (iOS 27.0) simulator
Scripts/build-device.sh --unsigned  # prepare iphoneos app and build manifest without signing
Scripts/build-device.sh --device <identifier>  # sign locally, install and launch on this paired phone
Scripts/test.sh                # swift test for every package, then the app test bundle on the simulator
```

Signed device builds read your team ID from `Signing.xcconfig`, which is gitignored. Copy
`Signing.xcconfig.example` and replace the placeholder locally. Find the phone identifier with
`xcrun devicectl list devices`; the script never chooses a device automatically. The default core
build requests no optional memory entitlements. Set `OMNIPLAY_ENTITLEMENTS_FILE` as shown in the
example only if your profile supports those capabilities. Keep `OMNIPLAY_BUNDLE_IDENTIFIER` and
your signing team stable for updates. `OmniPlay.xcodeproj` is generated and
gitignored: edit `project.yml`, not the project.

Unsigned output is `.build/DeviceDerivedData/Build/Products/Debug-iphoneos/OmniPlay.app`.
`.build/device-handoff/manifest.json` records the executable hash, source revision/dirty state,
SDK, requested entitlements and native dependency pins; `build.log` records the build. These are
local, gitignored outputs. An unsigned app cannot be installed until you sign it. Open the generated
project in Xcode, choose your team and phone, and build/run, or use the explicit `--device` command.

For phone acceptance, launch from the home screen without a debugger, import a game offline,
play, save, force-quit, relaunch and continue. Export a save before updating. Re-sign/install over
the existing app without uninstalling, then verify the save still loads. A successful build or
installation is not proof that every planned engine works.

## Before the first phone install

Everything up to the phone is checked by one command on the Mac:

```bash
Scripts/preflight.sh --release
```

It verifies the toolchain and every native artefact, runs the source-boundary checks and the eight tests
(packages, then the app and UI bundles on the simulator), builds the unsigned iphoneos app in Debug and Release, and
reports what signing still needs. Logs go to `.build/preflight/`. Do not install until it ends with every step
passing; `TODO`/`WARN` lines are the signing steps below.

1. Xcode → Settings → Accounts: add your Apple ID. A free account (Personal Team) works; apps it signs expire
   after 7 days and are reinstalled with the same command, keeping their data.
2. In `Signing.xcconfig`, set `DEVELOPMENT_TEAM` to your team ID and `OMNIPLAY_BUNDLE_IDENTIFIER` to one of your
   own (for example `com.yourname.omniplay`). Bundle IDs are unique across all Apple accounts; keep yours unchanged
   after the first install so updates keep your games and saves. Leave `OMNIPLAY_ENTITLEMENTS_FILE` unset on a free
   account.
3. Connect the iPhone by cable once, trust the Mac, and turn on Developer Mode (Settings → Privacy & Security).
4. `Scripts/build-device.sh --device <identifier> --release` (identifiers: `xcrun devicectl list devices`). The
   first run creates the signing certificate; on the phone, trust it under Settings → General → VPN & Device
   Management.

What only the phone can show: memory and heat on large WebGL and MZ games, the native engines' graphics (mkxp-z,
Ren'Py, EasyRPG, Godot) on real Metal, long-session memory (Ren'Py grows about 3 MB per game switch inside the
engine on the simulator), audio, haptics and touch ergonomics. Each session writes `memory.jsonl` beside its log,
which the per-game Diagnostics screen exports.

## Repository layout

| Path | Contents |
|---|---|
| `App/` | SwiftUI shell on the UIScene lifecycle, Info.plist, entitlements, asset catalog |
| `Packages/` | Local SwiftPM packages holding all non-UI logic; none of them import SwiftUI |
| `Native/` | Pinned upstream sources as submodules (libarchive, xz, zstd, later the engines); build outputs are gitignored |
| `Scripts/` | Bootstrap, project generation, build and test scripts |
| `Fixtures/synthetic/` | Deterministic test inputs with no game content |
| `Tests/` | App-level tests; each package carries its own test target |
| `LICENSES/` | Full licence texts of third-party components |
| `project.yml` | xcodegen specification for the app target and package graph |

## Third-party components and licences

Every bundled component is listed in `THIRD-PARTY-LICENSES.txt` with its licence text under
`LICENSES/`. Patches applied to GPL/LGPL engines are published in this repository.

## What is deliberately not here

- Design documents and the roadmap: they live outside the repository.
- Fixtures containing real games, RTPs or soundfonts: only synthetic fixtures are committed.
- Signing configuration and provisioning profiles.
- Prebuilt binaries, DerivedData and the generated Xcode project: all reproducible from source.

## Legal

Users supply their own legally obtained games. OmniPlay includes no game content, no RTPs and no
DRM circumvention. It is development-signed and sideloaded for personal use; it is not distributed.
