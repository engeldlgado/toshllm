#!/bin/zsh
# Builds the inference engines reproducibly:
#   1. Official llama.cpp + AMD patches  -> vendor/llama.cpp/build-static/bin
#   2. TurboQuant engine (llama.cpp PR 23962 + repair patches, optional)
#                                        -> vendor/llama.cpp-turbo/build-static/bin
#
# Usage:
#   ./scripts/build-engines.sh                  # host architecture, both engines
#   ARCH=x86_64 ./scripts/build-engines.sh      # cross-compile (CI on arm64 runners)
#   ARCH=universal ./scripts/build-engines.sh   # x86_64 + arm64 fat binaries (experimental)
#   SKIP_TURBO=1 ./scripts/build-engines.sh     # official engine only
set -e
cd "$(dirname "$0")/.."
ROOT="$PWD"

LLAMA_COMMIT="${LLAMA_COMMIT:-4fc4ec5}"   # llama.cpp commit validated against the patches
TURBO_COMMIT="${TURBO_COMMIT:-a3e3638}"   # head of llama.cpp PR 23962 (TurboQuant KV cache)
SD_COMMIT="${SD_COMMIT:-3590aa8}"         # stable-diffusion.cpp commit validated for image gen
ARCH="${ARCH:-$(uname -m)}"
if [ "$ARCH" = "universal" ]; then
    # Build each slice separately (ggml has per-arch sources) and lipo them.
    for slice in x86_64 arm64; do
        ARCH="$slice" SKIP_TURBO="$SKIP_TURBO" "$0"
        for dir in vendor/llama.cpp vendor/llama.cpp-turbo; do
            [ -d "$dir/build-static/bin" ] || continue
            for tool in llama-server llama-bench; do
                mv "$dir/build-static/bin/$tool" "$dir/build-static/bin/$tool.$slice" 2>/dev/null || true
            done
        done
    done
    for dir in vendor/llama.cpp vendor/llama.cpp-turbo; do
        [ -d "$dir/build-static/bin" ] || continue
        for tool in llama-server llama-bench; do
            if [ -f "$dir/build-static/bin/$tool.x86_64" ] && [ -f "$dir/build-static/bin/$tool.arm64" ]; then
                lipo -create -output "$dir/build-static/bin/$tool" \
                    "$dir/build-static/bin/$tool.x86_64" "$dir/build-static/bin/$tool.arm64"
                rm "$dir/build-static/bin/$tool".{x86_64,arm64}
            fi
        done
    done
    echo "universal engines ready"
    exit 0
fi

# The shader library is ALWAYS embedded (the binary stays self-contained, and
# the embedded source is the universal fallback that compiles at runtime). On
# top of that we ALSO ship a precompiled default.metallib next to the binary:
# embedding alone means every shader is compiled at runtime on each launch —
# tens of seconds for the large turbo kernel set (measured ~46 s for a 4B),
# which makes the app look stuck on startup. The patched ggml-metal-device.m
# loads that precompiled library in ~2 s on GPUs whose features match how it was
# built (no bfloat/tensor, i.e. Intel + AMD), and falls back to compiling the
# embedded source otherwise (Apple Silicon, older macOS, or a missing/bad lib).
# The .metallib is portable GPU AIR built for macOS 14+, so end users need
# nothing extra installed. Building it needs the Metal compiler from full Xcode's
# Metal Toolchain; we point at Xcode and download the component if missing.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if ! xcrun -f metal >/dev/null 2>&1; then
    xcodebuild -downloadComponent MetalToolchain >/dev/null 2>&1 || true
fi
if xcrun -f metal >/dev/null 2>&1; then
    METAL_PRECOMPILE=1
    echo "Metal compiler available — will precompile default.metallib (fast model load)"
else
    METAL_PRECOMPILE=0
    echo "Metal compiler unavailable — embedded source only (slower first load)"
fi

CMAKE_FLAGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_SHARED_LIBS=OFF
    -DGGML_METAL=ON
    -DGGML_METAL_EMBED_LIBRARY=ON
    -DGGML_NATIVE=OFF
    -DCMAKE_OSX_ARCHITECTURES="$ARCH"
    # The server binds to localhost only; skip OpenSSL so static cross-builds
    # don't pick up host-arch Homebrew libraries on CI runners.
    -DLLAMA_OPENSSL=OFF
)

build_engine() {
    local vendor="$1" ref="$2" fetch_ref="$3"
    shift 3
    local patches=("$@")

    if [ ! -d "$vendor/.git" ]; then
        git clone --filter=blob:none https://github.com/ggml-org/llama.cpp "$vendor"
    fi
    cd "$vendor"
    git fetch origin "$fetch_ref" 2>/dev/null || git fetch origin
    git checkout -qf "$ref"
    git checkout -- . 2>/dev/null || true

    for patch in "${patches[@]}"; do
        git apply "$ROOT/patches/$patch"
        echo "applied $patch"
    done

    cmake -B build-static "${CMAKE_FLAGS[@]}"
    cmake --build build-static --config Release -j "$(sysctl -n hw.ncpu)" -t llama-server llama-bench

    # Precompile the embedded shader source into a portable default.metallib so
    # the engine loads it instantly instead of compiling at runtime. Built from
    # the already-merged source the embed step produces, with the same EMBED
    # define and no bfloat/tensor macros, so it matches what the runtime would
    # compile for an Intel/AMD GPU; min macOS 14 to match the app's deployment
    # target. device.m only uses it on matching GPUs and falls back to the
    # embedded source otherwise, so this never breaks a load.
    local merged="build-static/ggml/src/ggml-metal/autogenerated/ggml-metal-embed.metal"
    if [ "$METAL_PRECOMPILE" = 1 ] && [ -f "$merged" ]; then
        if xcrun -sdk macosx metal -O3 -mmacosx-version-min=14.0 \
                -DGGML_METAL_EMBED_LIBRARY -DGGML_METAL_HAS_BF16 \
                -c "$merged" -o build-static/bin/ggml-metal.air &&
           xcrun -sdk macosx metallib build-static/bin/ggml-metal.air \
                -o build-static/bin/default.metallib; then
            rm -f build-static/bin/ggml-metal.air
            echo "precompiled default.metallib ($(du -h build-static/bin/default.metallib | cut -f1))"
        else
            rm -f build-static/bin/ggml-metal.air build-static/bin/default.metallib
            echo "WARNING: metallib precompile failed — falling back to runtime compile"
        fi
    fi
    echo "engine ready at $PWD/build-static/bin (arch: $ARCH)"
    cd "$ROOT"
}

# stable-diffusion.cpp image engine. Shares the ggml/Metal stack, so the AMD
# ggml-metal hunks of patch 0001 (ToshGEMM tiled matmul + staging transfers) apply
# cleanly to its bundled ggml and give ~2.9x faster sampling on RDNA. Only those
# hunks are taken; the llama-specific half of the patch has no counterpart here.
build_image_engine() {
    local vendor="vendor/stable-diffusion.cpp"
    # `git clone --recursive` stalls on the ggml submodule fetch on flaky links;
    # clone the main repo, then init the submodule separately, both abort-and-retry
    # on a stalled transfer instead of hanging.
    if [ ! -d "$vendor/.git" ]; then
        GIT_HTTP_LOW_SPEED_LIMIT=2000 GIT_HTTP_LOW_SPEED_TIME=30 \
            git clone https://github.com/leejet/stable-diffusion.cpp "$vendor"
    fi
    cd "$vendor"
    git fetch origin 2>/dev/null || true
    git checkout -qf "$SD_COMMIT"
    git submodule sync --recursive
    GIT_HTTP_LOW_SPEED_LIMIT=2000 GIT_HTTP_LOW_SPEED_TIME=30 \
        git submodule update --init --recursive
    git checkout -- . 2>/dev/null || true
    git -C ggml checkout -- . 2>/dev/null || true

    git apply --include='ggml/src/ggml-metal/*' -p1 "$ROOT/patches/0001-metal-amd-staging-transfers.patch"
    git apply --include='ggml/src/ggml-metal/*' -p1 "$ROOT/patches/0003-image-metal-ncb.patch"
    echo "applied ggml-metal hunks of 0001 + 0003 to stable-diffusion.cpp"

    cmake -B build-static \
        -DCMAKE_BUILD_TYPE=Release \
        -DSD_METAL=ON \
        -DGGML_METAL_EMBED_LIBRARY=ON \
        -DGGML_NATIVE=OFF \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH"
    cmake --build build-static --config Release -j "$(sysctl -n hw.ncpu)" -t sd-cli

    local merged="build-static/ggml/src/ggml-metal/autogenerated/ggml-metal-embed.metal"
    if [ "$METAL_PRECOMPILE" = 1 ] && [ -f "$merged" ]; then
        if xcrun -sdk macosx metal -O3 -mmacosx-version-min=14.0 \
                -DGGML_METAL_EMBED_LIBRARY -DGGML_METAL_HAS_BF16 \
                -c "$merged" -o build-static/bin/ggml-metal.air &&
           xcrun -sdk macosx metallib build-static/bin/ggml-metal.air \
                -o build-static/bin/default.metallib; then
            rm -f build-static/bin/ggml-metal.air
            echo "precompiled default.metallib for image engine"
        else
            rm -f build-static/bin/ggml-metal.air build-static/bin/default.metallib
        fi
    fi
    echo "image engine ready at $PWD/build-static/bin (arch: $ARCH)"
    cd "$ROOT"
}

# 1. Official engine
build_engine vendor/llama.cpp "$LLAMA_COMMIT" "$LLAMA_COMMIT" \
    0001-metal-amd-staging-transfers.patch

# 2. TurboQuant engine (from the upstream PR ref; skip with SKIP_TURBO=1)
if [ -z "$SKIP_TURBO" ]; then
    build_engine vendor/llama.cpp-turbo "$TURBO_COMMIT" "refs/pull/23962/head" \
        0002-turboquant-pr-fixes.patch
fi

# 3. Image engine (stable-diffusion.cpp; skip with SKIP_IMAGE=1)
if [ -z "$SKIP_IMAGE" ]; then
    build_image_engine
fi
