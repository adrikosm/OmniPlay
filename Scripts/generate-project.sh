#!/bin/zsh
# project.yml -> OmniPlay.xcodeproj. Creates a placeholder Signing.xcconfig when none exists so
# generation always succeeds; device builds then fail with a clear signing error until it is filled in.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f Signing.xcconfig ]] || { cp Signing.xcconfig.example Signing.xcconfig; echo "Signing.xcconfig created from the example: set DEVELOPMENT_TEAM before a device build."; }
xcodegen generate --quiet
echo "generated OmniPlay.xcodeproj"
