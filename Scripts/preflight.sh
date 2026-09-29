#!/bin/zsh
# Everything that must pass on the Mac before OmniPlay goes onto the phone, in one run:
#   toolchain → native artefacts → source boundaries → the eight tests (packages, then app and UI bundles on the
#   simulator) → an unsigned iphoneos build (catches device-only compile and link errors) → signing readiness.
# Nothing here signs, installs or touches a phone. Exit 0 only when every required step passed; warnings are
# printed but do not fail the run. Logs: .build/preflight/<step>.log
#
#   Scripts/preflight.sh            all steps
#   Scripts/preflight.sh --release  also build the optimised Release configuration for the device
set -uo pipefail
cd "$(dirname "$0")/.."
release=0
case "${1:-}" in
  "") ;;
  --release) release=1 ;;
  -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
  *) print -u2 "unknown option $1 (see --help)"; exit 2 ;;
esac

logs="$PWD/.build/preflight"
mkdir -p "$logs"
typeset -a report
failed=0

# step <name> <command...>: runs the command with its output in <name>.log, records PASS or FAIL.
step() {
  local name=$1; shift
  print -n "==> $name… "
  if "$@" > "$logs/$name.log" 2>&1; then
    print "ok"; report+=("PASS  $name")
  else
    print "FAILED"; report+=("FAIL  $name (log: .build/preflight/$name.log)"); failed=1
    tail -25 "$logs/$name.log" | sed 's/^/    /'
  fi
}
warn() { report+=("WARN  $1"); }

step toolchain Scripts/bootstrap-mac.sh
# Every manifest, not only the components hydrate.sh can rebuild: ScummVM, Godot, FFmpeg and the rest are linked or
# embedded by project.yml and must already be present.
step native-artefacts Scripts/native/verify.sh
step source-boundaries zsh -c 'Scripts/check-no-ui-imports.sh && Scripts/check-no-engine-checks-in-views.sh'
step eight-tests Scripts/test.sh
step device-build-unsigned Scripts/build-device.sh --unsigned
if (( release )); then
  step device-build-release Scripts/build-device.sh --unsigned --release
fi

# Signing readiness. These cannot be fixed by a script: they need your Apple ID in Xcode (Settings → Accounts).
team=$(awk -F= '/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print $2}' Signing.xcconfig 2>/dev/null)
if [[ -z "$team" || "$team" == REPLACE_ME ]]; then
  report+=("TODO  signing: set DEVELOPMENT_TEAM in Signing.xcconfig (Xcode → Settings → Accounts → your team's ID)")
else
  report+=("PASS  signing: team $team")
fi
bundle=$(awk -F= '/^[[:space:]]*OMNIPLAY_BUNDLE_IDENTIFIER[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print $2}' Signing.xcconfig 2>/dev/null)
if [[ -z "$bundle" || "$bundle" == com.omniplay.app ]]; then
  # Bundle IDs are unique across every Apple account; a shared default is likely taken, and registration then fails.
  warn "bundle id: set OMNIPLAY_BUNDLE_IDENTIFIER in Signing.xcconfig to one of your own (com.<you>.omniplay) before the first install; keep it unchanged afterwards so saves survive updates"
fi
if grep -qE '^[[:space:]]*OMNIPLAY_ENTITLEMENTS_FILE[[:space:]]*=[[:space:]]*[^[:space:]]' Signing.xcconfig 2>/dev/null; then
  warn "entitlements: OMNIPLAY_ENTITLEMENTS_FILE is set; a free (Personal Team) account cannot sign the increased-memory entitlements — leave it unset unless you have a paid membership"
fi
identities=$(security find-identity -v -p codesigning 2>/dev/null | awk '/valid identities found/ {print $1}')
if [[ "${identities:-0}" == 0 ]]; then
  warn "no code-signing identity yet: normal before the first device build; Xcode creates one when you are signed in and build with -allowProvisioningUpdates"
fi
devices=$(xcrun devicectl list devices 2>/dev/null | awk 'NR>2 && NF' | wc -l | tr -d ' ')
if [[ "${devices:-0}" == 0 ]]; then
  warn "no paired device: connect the iPhone once by cable, trust this Mac, and turn on Developer Mode (Settings → Privacy & Security)"
fi

print "\nPreflight summary"
printf '  %s\n' "${report[@]}"
if (( failed )); then
  print "\nNot ready: fix the FAILED steps above before installing on the phone."
  exit 1
fi
print "\nThe Mac side is ready. Next: Scripts/build-device.sh --device <identifier> --release (identifiers: xcrun devicectl list devices)"
