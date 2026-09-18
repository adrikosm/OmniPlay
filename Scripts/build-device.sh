#!/bin/zsh
# Build, install and launch OmniPlay on the first paired physical iPhone. Needs Signing.xcconfig with a
# real DEVELOPMENT_TEAM (copy Signing.xcconfig.example) and a paired device (Xcode 27 pairs wirelessly:
# Window > Devices and Simulators, with the phone unlocked and Developer Mode on).
set -euo pipefail
cd "$(dirname "$0")/.."
Scripts/generate-project.sh >/dev/null
grep -q 'REPLACE_ME' Signing.xcconfig && { echo "Signing.xcconfig still has the placeholder team. Set DEVELOPMENT_TEAM to your 10-character Apple Developer team ID." >&2; exit 1; }
udid="$(xcrun devicectl list devices -j "$(mktemp -t devices).json" >/dev/null 2>&1; xcrun devicectl list devices 2>/dev/null | awk '/paired/ && !/simulated/ {print $(NF-3)}' | head -1)"
[[ -n "$udid" ]] || { echo "No paired iPhone. Connect or pair the phone (Xcode > Window > Devices and Simulators), unlock it, enable Developer Mode, then retry." >&2; exit 1; }
xcodebuild -project OmniPlay.xcodeproj -scheme OmniPlay -destination "id=$udid" -derivedDataPath .build/DerivedData -allowProvisioningUpdates build -quiet
app="$(find .build/DerivedData/Build/Products/Debug-iphoneos -maxdepth 1 -name OmniPlay.app)"
xcrun devicectl device install app --device "$udid" "$app"
xcrun devicectl device process launch --device "$udid" com.omniplay.app
echo "OmniPlay running on device $udid"
