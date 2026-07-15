#!/bin/zsh
# Packages ToshLLM as a native .app bundle.
# TOSH_ARCH=x86_64 ./make-app.sh  -> cross-compile (CI on Apple Silicon runners)
set -e
cd "$(dirname "$0")"

# Version: the VERSION file is the single source of truth. Each packaging
# build bumps the last component automatically (0.81.1 -> 0.81.2). For a
# minor/major release set it explicitly: TOSH_VERSION=0.82 ./make-app.sh
# CI builds (CI=true) and TOSH_NO_BUMP=1 use the committed version as-is.
if [ -n "$TOSH_VERSION" ]; then
    VERSION="$TOSH_VERSION"
    echo "$VERSION" > VERSION
elif [ -z "$CI" ] && [ "$TOSH_NO_BUMP" != "1" ]; then
    VERSION=$(<VERSION)
    VERSION="${VERSION%.*}.$(( ${VERSION##*.} + 1 ))"
    echo "$VERSION" > VERSION
else
    VERSION=$(<VERSION)
fi
sed -i '' -E "s/static let version = \"[^\"]*\"/static let version = \"$VERSION\"/" Sources/AboutTab.swift
echo "version: $VERSION"

# Stamp the no-AVX2 variant so the updater keeps it on its own channel (an AVX2 DMG
# would SIGILL on those CPUs). Set via TOSH_NO_AVX2=1 alongside build-engines.sh.
NOAVX2=$([ "$TOSH_NO_AVX2" = "1" ] && echo true || echo false)
echo "no-AVX2 variant: $NOAVX2"

if [ "$TOSH_ARCH" = "universal" ]; then
    swift build -c release --arch x86_64 --arch arm64
    SWIFT_BIN=".build/apple/Products/Release/ToshLLM"
elif [ -n "$TOSH_ARCH" ]; then
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
    # llama-perplexity ships so testers can run numeric A/Bs without building
    cp "$LLAMA_STATIC/llama-server" "$LLAMA_STATIC/llama-bench" "$LLAMA_STATIC/llama-perplexity" "$APP/Contents/Resources/bin/"
    # Precompiled Metal library (loaded instead of compiling shaders at runtime;
    # see ggml-metal-device.m). Optional: without it the engine still works,
    # just slower to load. Must sit next to the binary.
    [ -f "$LLAMA_STATIC/default.metallib" ] && cp "$LLAMA_STATIC/default.metallib" "$APP/Contents/Resources/bin/"
    echo "bundled static llama-server/llama-bench from $LLAMA_STATIC"
else
    echo "WARNING: engines not built; run ./scripts/build-engines.sh first"
fi

# Web chat UI (served via llama-server --path)
mkdir -p "$APP/Contents/Resources/test-ui"
cp Assets/test-ui/index.html "$APP/Contents/Resources/test-ui/"

# Community translation overlays (English-string -> translation). Optional:
# es/en are built in; missing keys fall back to English. Copied both for the
# native app (Resources/lang) and for the web console to fetch (test-ui/lang).
if ls Assets/lang/*.json >/dev/null 2>&1; then
    mkdir -p "$APP/Contents/Resources/lang" "$APP/Contents/Resources/test-ui/lang"
    for f in Assets/lang/*.json; do
        [[ "$(basename "$f")" == _* ]] && continue   # skip _template.json
        cp "$f" "$APP/Contents/Resources/lang/"
        cp "$f" "$APP/Contents/Resources/test-ui/lang/"
    done
fi

# Binance Pay QR (cropped) for the donations popup
[ -f Assets/binance-qr.png ] && cp Assets/binance-qr.png "$APP/Contents/Resources/binance-qr.png"


# Image generation engine (stable-diffusion.cpp; optional)
IMAGE_STATIC="vendor/stable-diffusion.cpp/build-static/bin"
if [ -x "$IMAGE_STATIC/sd-cli" ]; then
    mkdir -p "$APP/Contents/Resources/bin-image"
    cp "$IMAGE_STATIC/sd-cli" "$APP/Contents/Resources/bin-image/"
    [ -f "$IMAGE_STATIC/default.metallib" ] && cp "$IMAGE_STATIC/default.metallib" "$APP/Contents/Resources/bin-image/"
    echo "bundled image generation engine"
fi

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
    <key>TOSHNoAVX2</key>              <$NOAVX2/>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key> <true/>
    </dict>
    <key>NSLocalNetworkUsageDescription</key>
    <string>ToshLLM can expose and advertise its local OpenAI-compatible API to devices on your trusted local network.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_http._tcp.</string>
    </array>
</dict>
</plist>
EOF

# macOS 26 Liquid Glass icon: compile the layered AppIcon.icon when the
# toolchain has actool 26+; ships Assets.car plus a freshly rendered legacy
# icns. Without it the repo icns above remains the icon.
# CLT-only setups need Xcode.app spelled out (same story as scripts/test.sh).
ACTOOL=$(xcrun --find actool 2>/dev/null || true)
if [ -z "$ACTOOL" ] && [ -x /Applications/Xcode.app/Contents/Developer/usr/bin/actool ]; then
    ACTOOL=/Applications/Xcode.app/Contents/Developer/usr/bin/actool
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if [ -d AppIcon.icon ] && [ -n "$ACTOOL" ]; then
    ICONTMP=$(mktemp -d)
    if "$ACTOOL" AppIcon.icon --compile "$ICONTMP" --platform macosx \
        --minimum-deployment-target 14.0 --app-icon AppIcon \
        --output-partial-info-plist "$ICONTMP/icon.plist" > /dev/null 2>&1 \
        && [ -f "$ICONTMP/Assets.car" ]; then
        cp "$ICONTMP/Assets.car" "$APP/Contents/Resources/"
        [ -f "$ICONTMP/AppIcon.icns" ] && cp "$ICONTMP/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
        /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
        echo "bundled Liquid Glass icon (Assets.car + rendered icns)"
    fi
    rm -rf "$ICONTMP"
fi

[ -x "$APP/Contents/Resources/bin/llama-server" ] && codesign --force -s - "$APP/Contents/Resources/bin/"*
[ -x "$APP/Contents/Resources/bin-image/sd-cli" ] && codesign --force -s - "$APP/Contents/Resources/bin-image/"*
codesign --force -s - "$APP"
echo "Done: $APP"
