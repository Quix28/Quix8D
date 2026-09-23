#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Build outside Desktop/Documents: iCloud adds Finder metadata that breaks codesign.
SCRATCH_PATH="$HOME/Library/Caches/Quix8D/build"
# Universal: runs natively on Apple silicon and Intel.
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}" --scratch-path "$SCRATCH_PATH"
BIN_PATH=$(swift build -c release "${ARCHS[@]}" --scratch-path "$SCRATCH_PATH" --show-bin-path)

APP="$SCRATCH_PATH/Quix8D.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/Quix8D" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/"

# Stable identity, not ad-hoc: TCC keys an ad-hoc grant to the binary hash,
# so each rebuild would lose the audio permission.
if codesign --sign "Apple Development" --force --deep "$APP" 2>/dev/null; then
    echo "Signed with Apple Development identity"
else
    echo "No Apple Development identity found — falling back to ad-hoc signing (permission grant will not survive a rebuild)"
    codesign --sign - --force --deep "$APP"
fi

rm -rf "build/Quix8D.app"
mkdir -p build
ditto "$APP" "build/Quix8D.app"
echo "Built: build/Quix8D.app"
