#!/bin/zsh
# Command Line Tools only packaging for macOS 12 (Intel, no AVX2).
#
# This host has no SwiftPM (PackageDescription is missing) and no actool, so the
# module is compiled by calling swiftc directly and the bundle is assembled from
# the same resources make-app.sh uses. Iteration uses -Onone; TOSH_OPT=1 links
# the optimised build.
set -e
cd "$(dirname "$0")"

VERSION=$(<VERSION)
SDK=$(xcrun --show-sdk-path)
TARGET=x86_64-apple-macosx12.0
APP="dist/ToshLLM.app"

OPT=(-Onone)
[ "$TOSH_OPT" = 1 ] && OPT=(-O)

echo "compiling $(find Sources -name '*.swift' | wc -l | tr -d ' ') files for $TARGET"
mkdir -p build
xcrun swiftc -parse-as-library -target "$TARGET" -sdk "$SDK" \
    -num-threads "$(sysctl -n hw.ncpu)" "${OPT[@]}" \
    -o build/ToshLLM $(find Sources -name '*.swift')

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/ToshLLM "$APP/Contents/MacOS/ToshLLM"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Engines built by scripts/build-engines.sh (TOSH_NO_AVX2=1 ARCH=x86_64
# DEPLOYMENT_TARGET=12.0). Missing engines leave the app runnable but idle.
LLAMA_STATIC="vendor/llama.cpp/build-static/bin"
if [ -x "$LLAMA_STATIC/llama-server" ]; then
    mkdir -p "$APP/Contents/Resources/bin"
    cp "$LLAMA_STATIC/llama-server" "$LLAMA_STATIC/llama-bench" "$APP/Contents/Resources/bin/"
    [ -f "$LLAMA_STATIC/test-backend-ops" ] && cp "$LLAMA_STATIC/test-backend-ops" "$APP/Contents/Resources/bin/"
    [ -d "$LLAMA_STATIC/kernels" ] && cp -R "$LLAMA_STATIC/kernels" "$APP/Contents/Resources/bin/"
    echo "bundled engines from $LLAMA_STATIC"
else
    echo "WARNING: engines not built; run ./scripts/build-engines.sh first"
fi

for dir in test-ui web-ui lang model-icons rich-content; do
    [ -d "Assets/$dir" ] || continue
    mkdir -p "$APP/Contents/Resources/$dir"
    (cd "Assets/$dir" && tar cf - .) | (cd "$APP/Contents/Resources/$dir" && tar xf -)
done
cp Assets/test-ui/index.html "$APP/Contents/Resources/test-ui/" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>ToshLLM</string>
    <key>CFBundleDisplayName</key>     <string>ToshLLM</string>
    <key>CFBundleIdentifier</key>      <string>dev.engel.toshllm</string>
    <key>CFBundleExecutable</key>      <string>ToshLLM</string>
    <key>CFBundleVersion</key>         <string>$VERSION</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>TOSHNoAVX2</key>              <true/>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>12.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key> <true/>
    </dict>
    <key>NSLocalNetworkUsageDescription</key>
    <string>ToshLLM can expose and advertise its local OpenAI-compatible API to devices on your trusted local network.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>ToshLLM records audio only when you press the microphone button, for local transcription or an audio-capable model.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>ToshLLM uses Apple's on-device speech recognition only when you select Apple Dictation and press the microphone button.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_http._tcp.</string>
    </array>
</dict>
</plist>
EOF

# Every Mach-O in the bundle has to target 12 or the app dies in dyld on boot.
for exe in "$APP/Contents/MacOS/ToshLLM" "$APP/Contents/Resources/bin/"*(N); do
    [ -f "$exe" ] || continue
    case "$exe" in *.metallib) continue;; esac
    minos=$(otool -l "$exe" 2>/dev/null | awk '/LC_BUILD_VERSION/{f=1} f&&/^ *minos/{print $2; exit}')
    [ -z "$minos" ] && continue
    if [ "${minos%%.*}" -gt 12 ]; then
        echo "ERROR: $(basename "$exe") targets macOS $minos; this bundle runs on 12.0+" >&2
        exit 1
    fi
done

if [ -x "$APP/Contents/Resources/bin/llama-server" ]; then
    # only the Mach-O binaries: the kernels directory inside bin/ is not a bundle
    # and codesign rejects it, which would skip the app signing below.
    for exe in "$APP/Contents/Resources/bin/"*(N.); do
        case "$exe" in *.metallib) continue;; esac
        codesign --force -s - "$exe"
    done
fi
codesign --force --entitlements ToshLLM.entitlements -s - "$APP"
echo "Done: $APP"
