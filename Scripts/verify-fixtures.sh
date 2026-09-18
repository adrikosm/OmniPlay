#!/bin/zsh
# Every synthetic fixture matches MANIFEST.sha256 and nothing unlisted is present.
set -uo pipefail
cd "$(dirname "$0")/../Fixtures/synthetic" || exit 1
mkdir -p empty
shasum -a 256 -c MANIFEST.sha256 --quiet || { echo "verify-fixtures: hash mismatch"; exit 1; }
extra=$(comm -13 <(awk '{print $2}' MANIFEST.sha256 | sort) <(find . -type f ! -name MANIFEST.sha256 ! -name .DS_Store | sed 's|^\./||' | sort))
[[ -n "$extra" ]] && { echo "verify-fixtures: unlisted files:"; echo "$extra"; exit 1; }
echo "verify-fixtures: OK ($(wc -l < MANIFEST.sha256 | tr -d ' ') files)"
