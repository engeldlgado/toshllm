#!/bin/zsh
# Packages ToshLLM as a native .app bundle.
# TOSH_ARCH=x86_64 ./make-app.sh  -> cross-compile (CI on Apple Silicon runners)
set -e
cd "$(dirname "$0")"

if [ -n "$TOSH_ARCH" ]; then
    swift build -c release --arch "$TOSH_ARCH"
    SWIFT_BIN=".build/$TOSH_ARCH-apple-macosx/release/ToshLLM"
else
    swift build -c release
    SWIFT_BIN=".build/release/ToshLLM"
fi

APP="dist/ToshLLM.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$SWIFT_BIN" "$APP/Contents/MacOS/ToshLLM"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# llama.cpp binaries (static build = portable): vendor/ first (reproducible,
# produced by scripts/build-engines.sh), then the local development checkout.
LLAMA_STATIC="vendor/llama.cpp/build-static/bin"
[ -x "$LLAMA_STATIC/llama-server" ] || LLAMA_STATIC="$HOME/dev/repositorios/llama.cpp/build-static/bin"
if [ -x "$LLAMA_STATIC/llama-server" ]; then
    mkdir -p "$APP/Contents/Resources/bin"
    cp "$LLAMA_STATIC/llama-server" "$LLAMA_STATIC/llama-bench" "$APP/Contents/Resources/bin/"
    echo "bundled static llama-server/llama-bench from $LLAMA_STATIC"
else
    echo "WARNING: engines not built; run ./scripts/build-engines.sh first"
fi

# Web chat UI (served via llama-server --path)
mkdir -p "$APP/Contents/Resources/test-ui"
cp Assets/test-ui/index.html "$APP/Contents/Resources/test-ui/"

# Binance Pay QR (cropped) for the donations popup
[ -f Assets/binance-qr.png ] && cp Assets/binance-qr.png "$APP/Contents/Resources/binance-qr.png"

# Experimental TurboQuant engine (optional)
TURBO_STATIC="$HOME/dev/repositorios/llama.cpp-turboquant/build-static/bin"
if [ -x "$TURBO_STATIC/llama-server" ]; then
    mkdir -p "$APP/Contents/Resources/bin-turbo"
    cp "$TURBO_STATIC/llama-server" "$TURBO_STATIC/llama-bench" "$APP/Contents/Resources/bin-turbo/"
    echo "bundled TurboQuant engine (experimental)"
fi

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>ToshLLM</string>
    <key>CFBundleDisplayName</key>     <string>ToshLLM</string>
    <key>CFBundleIdentifier</key>      <string>dev.engel.toshllm</string>
    <key>CFBundleExecutable</key>      <string>ToshLLM</string>
    <key>CFBundleVersion</key>         <string>0.81.1</string>
    <key>CFBundleShortVersionString</key> <string>0.81.1</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key> <true/>
    </dict>
</dict>
</plist>
EOF

[ -x "$APP/Contents/Resources/bin/llama-server" ] && codesign --force -s - "$APP/Contents/Resources/bin/"*
[ -x "$APP/Contents/Resources/bin-turbo/llama-server" ] && codesign --force -s - "$APP/Contents/Resources/bin-turbo/"*
codesign --force -s - "$APP"
echo "Done: $APP"
