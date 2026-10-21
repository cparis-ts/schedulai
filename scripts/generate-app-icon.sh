#!/bin/bash
# Regenerates Resources/AppIcon.icns from scripts/generate-app-icon.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SET="$ROOT/Resources/AppIcon.iconset"
rm -rf "$SET"; mkdir -p "$SET"
/usr/bin/swift "$ROOT/scripts/generate-app-icon.swift" "$SET/icon_512x512@2x.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$SET/icon_512x512@2x.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$SET/icon_512x512@2x.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$ROOT/Resources/AppIcon.icns"
rm -rf "$SET"
