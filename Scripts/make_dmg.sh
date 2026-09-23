#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

./Scripts/build_app_bundle.sh

STAGING="$HOME/Library/Caches/Quix8D/dmg"
DMG="build/Quix8D.dmg"

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
ditto "build/Quix8D.app" "$STAGING/Quix8D.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "Quix8D" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
echo "Built: $DMG"
