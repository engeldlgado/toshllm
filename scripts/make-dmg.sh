#!/bin/zsh
# Creates an installable .dmg (drag to Applications) from dist/ToshLLM.app
set -e
cd "$(dirname "$0")/.."

VERSION="${1:-v$(<VERSION)}"
APP="dist/ToshLLM.app"

[ -d "$APP" ] || { echo "$APP not found — run ./make-app.sh first"; exit 1; }

# The no-AVX2 legacy build ships as a distinctly named DMG so it stays on its own
# update channel. Read the variant straight from the built bundle (single source).
SUFFIX=""
if /usr/libexec/PlistBuddy -c "Print :TOSHNoAVX2" "$APP/Contents/Info.plist" 2>/dev/null | grep -qi true; then
    SUFFIX="-noavx2"
fi
DMG="dist/ToshLLM-$VERSION$SUFFIX.dmg"

STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "ToshLLM" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

echo "Done: $DMG"
