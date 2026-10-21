#!/bin/bash
# Build Schedulai and assemble "Schedulai.app", signed ad-hoc.
# Usage: [VERSION=x.y.z] scripts/build-app.sh [OUTPUT_DIR]   (default: ./build). Prints the bundle path last.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${1:-$ROOT/build}"
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"

cd "$ROOT"
/usr/bin/swift build -c release
BIN="$(/usr/bin/swift build -c release --show-bin-path)/Schedulai"
[[ -f Resources/AppIcon.icns ]] || scripts/generate-app-icon.sh

APP="$OUTPUT/Schedulai.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Schedulai"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/run-job.sh Resources/AppIcon.icns skill/schedulai/SKILL.md "$APP/Contents/Resources/"
# VERSION=1.2.0 (the release workflow passes the tag) stamps the bundle.
if [[ -n "${VERSION:-}" ]]; then
  /usr/bin/plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
  /usr/bin/plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
fi
/usr/bin/codesign --force --sign - "$APP"
echo "$APP"
