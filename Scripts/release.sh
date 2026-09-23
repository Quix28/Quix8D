#!/bin/bash
# Usage: ./Scripts/release.sh 1.1 "What changed"
# Bumps the version, builds the DMG, syncs the public repo (without docs/)
# and publishes a GitHub release that installed apps pick up via the update button.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh <version> [notes]}"
NOTES="${2:-Quix8D $VERSION}"
PUBLIC_REPO="Quix28/Quix8D"
PUBLIC_DIR="${PUBLIC_DIR:-$HOME/Library/Caches/Quix8D/public}"

[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "Commit your changes first."; exit 1; }

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
git commit -q -m "chore(release): v$VERSION" -- Resources/Info.plist
git push -q origin HEAD:main

./Scripts/make_dmg.sh
DMG="build/Quix8D-$VERSION.dmg"

[ -d "$PUBLIC_DIR/.git" ] || gh repo clone "$PUBLIC_REPO" "$PUBLIC_DIR"
git -C "$PUBLIC_DIR" pull -q --ff-only
EXPORT=$(mktemp -d)
git archive HEAD | tar -x -C "$EXPORT"
rm -rf "$EXPORT/docs"
rsync -a --delete --exclude .git "$EXPORT/" "$PUBLIC_DIR/"
rm -rf "$EXPORT"
git -C "$PUBLIC_DIR" add -A
git -C "$PUBLIC_DIR" commit -q -m "release: v$VERSION"
git -C "$PUBLIC_DIR" push -q origin main

gh release create "v$VERSION" "$DMG" --repo "$PUBLIC_REPO" --target main --title "Quix8D $VERSION" --notes "$NOTES"
echo "Released v$VERSION"
