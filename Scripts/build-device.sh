#!/bin/zsh
# Prepare an unsigned iphoneos app, or build/install on an explicitly selected device.
set -euo pipefail
cd "$(dirname "$0")/.."
usage() {
  cat <<'HELP'
Usage: Scripts/build-device.sh --unsigned [--release]
       Scripts/build-device.sh --device <identifier> [--release]

--unsigned  Build without signing or installing; no account/device required.
--device    Sign using local Signing.xcconfig, then install and launch on this device.
--release   Optimised Release configuration (what to play on the phone); Debug otherwise.
Find identifiers with: xcrun devicectl list devices
Output: .build/DeviceDerivedData/Build/Products/<Debug|Release>-iphoneos/OmniPlay.app
Evidence: .build/device-handoff/manifest.json and build.log
HELP
}
mode=""; device=""; configuration=Debug
while (( $# )); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --unsigned) [[ -z "$mode" ]] || { usage >&2; exit 2; }; mode=--unsigned ;;
    --device)
      [[ -z "$mode" && $# -ge 2 && -n "$2" && "$2" != -* ]] || { usage >&2; exit 2; }
      mode=--device; device="$2"; shift ;;
    --release) configuration=Release ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$mode" ]] || { usage >&2; exit 2; }

out="$PWD/.build/device-handoff"
mkdir -p "$out"
# An earlier manifest must not look like evidence for a failed new attempt.
rm -f "$out/manifest.json"
# The owner's RTPs go into the phone build when they are on this Mac and not bundled yet.
[[ -d Native/prebuilt/rtp/RTP || ! -d Fixtures/private/rtp ]] || Scripts/native/bundle-rtp.sh
Scripts/generate-project.sh
args=(-project OmniPlay.xcodeproj -scheme OmniPlay -configuration "$configuration" -sdk iphoneos
      -derivedDataPath .build/DeviceDerivedData)
if [[ "$mode" == --unsigned ]]; then
  args+=(-destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO)
else
  args+=(-destination "id=$device" -allowProvisioningUpdates)
fi
xcodebuild "${args[@]}" -showBuildSettings -json > "$out/build-settings.json"
if [[ "$mode" == --device ]]; then
  python3 - "$out/build-settings.json" <<'PY'
import json, sys
settings = next(t['buildSettings'] for t in json.load(open(sys.argv[1])) if t['target'] == 'OmniPlay')
team = settings.get('DEVELOPMENT_TEAM', '').strip()
if not team or team == 'REPLACE_ME':
    sys.exit('Set DEVELOPMENT_TEAM in local Signing.xcconfig, or use --unsigned to prepare without signing.')
PY
fi
print "Building iphoneos app ($mode, $configuration); log: $out/build.log"
if ! xcodebuild "${args[@]}" build -quiet > "$out/build.log" 2>&1; then
  tail -60 "$out/build.log" >&2
  print -u2 "Device build failed. Full log: $out/build.log"
  exit 1
fi

python3 - "$out" "$mode" <<'PY'
import datetime, hashlib, json, pathlib, plistlib, subprocess, sys
out = pathlib.Path(sys.argv[1])
settings = next(t['buildSettings'] for t in json.loads((out/'build-settings.json').read_text()) if t['target'] == 'OmniPlay')
app = pathlib.Path(settings['TARGET_BUILD_DIR']) / settings['FULL_PRODUCT_NAME']
with (app/'Info.plist').open('rb') as f:
    info = plistlib.load(f)
def sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()
def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()
entitlements_file = settings.get('CODE_SIGN_ENTITLEMENTS', '')
entitlements = {}
if entitlements_file:
    path = pathlib.Path(entitlements_file)
    if not path.is_absolute():
        path = pathlib.Path(settings['SRCROOT']) / path
    with path.open('rb') as f:
        entitlements = plistlib.load(f)
components = []
for path in sorted(pathlib.Path('Native/manifests').glob('*.json')):
    m = json.loads(path.read_text())
    components.append({k: m.get(k) for k in ('component', 'sources', 'built_at', 'toolchain', 'sdks')}
                      | {'manifest_sha256': sha(path), 'output_count': len(m.get('outputs', {}))})
manifest = {
    'created_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'mode': sys.argv[2].removeprefix('--'), 'configuration': settings['CONFIGURATION'], 'app_path': str(app),
    'bundle_id': info['CFBundleIdentifier'], 'version': info['CFBundleShortVersionString'],
    'build': info['CFBundleVersion'], 'minimum_ios': info['MinimumOSVersion'],
    'sdk': settings['SDK_NAME'], 'architecture': settings['ARCHS'],
    'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
    'source_commit': git('rev-parse', 'HEAD'),
    'worktree_dirty': bool(git('status', '--porcelain')),
    'executable_sha256': sha(app/info['CFBundleExecutable']),
    'requested_entitlements': entitlements, 'native_components': components,
    'validation': 'Build only; no physical-device gameplay or save acceptance inferred.',
}
(out/'manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
print(f"Built: {app}\nManifest: {out/'manifest.json'}")
PY

if [[ "$mode" == --unsigned ]]; then
  print "Unsigned preparation complete. Open OmniPlay.xcodeproj and sign locally before installing."
else
  app=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["app_path"])' "$out/manifest.json")
  bundle=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["bundle_id"])' "$out/manifest.json")
  xcrun devicectl device install app --device "$device" "$app"
  xcrun devicectl device process launch --device "$device" "$bundle"
  print "OmniPlay launched on selected device. Run the personal-device acceptance walkthrough next."
fi
