#!/bin/zsh
# Creates an installable .dmg (drag to Applications) from dist/ToshLLM.app
set -e
cd "$(dirname "$0")/.."

VERSION="${1:-v$(<VERSION)}"
APP="dist/ToshLLM.app"
DMG="dist/ToshLLM-$VERSION.dmg"

[ -d "$APP" ] || { echo "$APP not found — run ./make-app.sh first"; exit 1; }

STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "ToshLLM" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

echo "Done: $DMG"
