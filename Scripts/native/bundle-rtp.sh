#!/bin/zsh
# Copies the owner's extracted RPG Maker RTPs into Native/prebuilt/rtp/RTP/<family>, which project.yml bundles as
# <app>/RTP so RTP games play without an import. The RTPs are the owner's own copies from Fixtures/private/rtp
# (unpacked from the official installers on a Mac); they are gitignored and never committed. A missing one is skipped.
source "$(dirname "$0")/common.sh"
cd "$NATIVE_ROOT"
SRC="Fixtures/private/rtp"
OUT="Native/prebuilt/rtp/RTP"
/bin/rm -rf "$OUT"; mkdir -p "$OUT"
# family folder <- source folder (innoextract leaves the payload in app/; 2000/2003 RTPs are already plain folders)
for pair in XP:xp/app VX:vx/app VXAce:vxace/app RPG2000:rpg2000 RPG2003:rpg2003; do
  family=${pair%%:*} from="$SRC/${pair#*:}"
  [[ -d "$from" ]] || { echo "skip $family: no $from"; continue; }
  mkdir -p "$OUT/$family"
  rsync -a --exclude '*.exe' --exclude '*.dll' --exclude '*.ico' "$from/" "$OUT/$family/"
  print -n "Built in" > "$OUT/$family/.omniplay-variant"
  echo "$family: $(find "$OUT/$family" -type f | wc -l | tr -d ' ') files, $(du -sh "$OUT/$family" | cut -f1)"
done
