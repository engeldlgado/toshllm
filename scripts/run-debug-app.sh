#!/bin/sh
# Run the SPM debug build as a real GUI app.
#
# A bare .build/debug/ToshLLM has no bundle or Info.plist, so LaunchServices
# checks it in as BackgroundOnly: no Dock icon, no activation, and its windows
# never come forward (it looks like the app did not launch at all). Wrapping
# the binary in a minimal .app makes it a regular foreground app again.
#
# Debug builds get their own bundle id (…toshllm.debug), so UserDefaults stays
# in a separate domain and a debug run never touches the installed app's
# settings or profiles.
set -eu
cd "$(dirname "$0")/.."
BIN=".build/debug/ToshLLM"
APP=".build/ToshLLM-debug.app"

[ -x "$BIN" ] || { echo "No debug build. Run: swift build" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>              <string>ToshLLM</string>
    <key>CFBundleIdentifier</key>              <string>dev.engel.toshllm.debug</string>
    <key>CFBundleName</key>                    <string>ToshLLM (debug)</string>
    <key>CFBundlePackageType</key>             <string>APPL</string>
    <key>CFBundleShortVersionString</key>      <string>$(cat VERSION)-debug</string>
    <key>CFBundleVersion</key>                 <string>1</string>
    <key>LSMinimumSystemVersion</key>          <string>14.0</string>
    <key>NSHighResolutionCapable</key>         <true/>
</dict>
</plist>
EOF
# Copy (not symlink): LaunchServices wants a real file at the bundle path.
cp "$BIN" "$APP/Contents/MacOS/ToshLLM"
exec open "$APP"
