#!/usr/bin/env bash
# Build a release .app (same steps as .github/workflows/release.yml) and
# install it to /Applications, or ~/Applications if /Applications is not writable.
set -euo pipefail

cd "$(dirname "$0")"
source scripts/select-sdk.sh

swift build -c release

STAGE=".build/install/Swift Hakchi2.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp .build/release/SwiftHakchi "$STAGE/Contents/MacOS/SwiftHakchi"
cp -R .build/release/SwiftHakchi_SwiftHakchi.bundle "$STAGE/Contents/Resources/"
cp SwiftHakchi/Resources/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
cp Info.plist "$STAGE/Contents/Info.plist"
codesign -s - --deep --force "$STAGE"

DEST_DIR="/Applications"
[[ -w "$DEST_DIR" ]] || DEST_DIR="$HOME/Applications"
mkdir -p "$DEST_DIR"

# Quit a running copy before replacing it
pkill -f "Swift Hakchi2.app/Contents/MacOS/SwiftHakchi" 2>/dev/null || true
rm -rf "$DEST_DIR/Swift Hakchi2.app"
ditto "$STAGE" "$DEST_DIR/Swift Hakchi2.app"

echo "Installed to $DEST_DIR/Swift Hakchi2.app"
