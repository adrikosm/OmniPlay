#!/bin/zsh
# Build, install and launch OmniPlay on the iPhone 17 Pro Max / iOS 27.0 simulator.
# Installs the iOS 27.0 runtime and creates the device when they are missing.
set -euo pipefail
cd "$(dirname "$0")/.."
Scripts/generate-project.sh >/dev/null
name="iPhone 17 Pro Max"; ios="27.0"
runtime_id() { xcrun simctl list runtimes -j | python3 -c "import json,sys; print(next((r['identifier'] for r in json.load(sys.stdin)['runtimes'] if r['platform']=='iOS' and r['version']=='$ios' and r['isAvailable']),''))"; }
rt="$(runtime_id)"
if [[ -z "$rt" ]]; then
  echo "iOS $ios simulator runtime missing: downloading (xcodebuild -downloadPlatform iOS)"; xcodebuild -downloadPlatform iOS
  rt="$(runtime_id)"; [[ -n "$rt" ]] || { echo "iOS $ios runtime still missing after download" >&2; exit 1; }
fi
udid="$(xcrun simctl list devices -j | python3 -c "import json,sys; d=json.load(sys.stdin)['devices']; print(next((x['udid'] for x in d.get('$rt',[]) if x['name']=='$name' and x['isAvailable']),''))")"
if [[ -z "$udid" ]]; then
  dt="$(xcrun simctl list devicetypes -j | python3 -c "import json,sys; print(next(t['identifier'] for t in json.load(sys.stdin)['devicetypes'] if t['name']=='$name'))")"
  udid="$(xcrun simctl create "$name" "$dt" "$rt")"; echo "created simulator $name ($ios): $udid"
fi
xcrun simctl boot "$udid" 2>/dev/null || true
xcodebuild -project OmniPlay.xcodeproj -scheme OmniPlay -destination "id=$udid" -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build -quiet
app="$(find .build/DerivedData/Build/Products/Debug-iphonesimulator -maxdepth 1 -name OmniPlay.app)"
xcrun simctl install "$udid" "$app"
open -b com.apple.iphonesimulator --args -CurrentDeviceUDID "$udid" 2>/dev/null || echo "(Simulator UI not registered with Launch Services; the app is running headless, attach a viewer or open Simulator from Xcode)"
pid="$(xcrun simctl launch "$udid" com.omniplay.app | awk '{print $NF}')"
echo "OmniPlay running on $name ($ios) [$udid], pid $pid"
