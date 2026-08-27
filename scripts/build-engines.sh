#!/bin/zsh
# Builds the inference engines reproducibly:
#   1. Official llama.cpp + AMD patches  -> vendor/llama.cpp/build-static/bin
#   2. whisper.cpp speech-to-text        -> vendor/whisper.cpp/build-static/bin
#
# Usage:
#   ./scripts/build-engines.sh                  # host architecture
#   ARCH=x86_64 ./scripts/build-engines.sh      # cross-compile (CI on arm64 runners)
#   ARCH=universal ./scripts/build-engines.sh   # x86_64 + arm64 fat binaries (experimental)
set -e
cd "$(dirname "$0")/.."
ROOT="$PWD"

LLAMA_COMMIT="${LLAMA_COMMIT:-3dc7285b4}"   # llama.cpp commit validated against the patches
WHISPER_COMMIT="${WHISPER_COMMIT:-371b5a7561823ab2bb32142d2751e35e7534727b}" # whisper.cpp v1.9.3
SD_COMMIT="${SD_COMMIT:-97d2990}"         # stable-diffusion.cpp commit validated for image gen
ARCH="${ARCH:-$(uname -m)}"
DEPLOYMENT_TARGET="14.0"        # same floor as the app (Package.swift)
if [ "$ARCH" = "universal" ]; then
    # Build each slice separately (ggml has per-arch sources) and lipo them.
    for slice in x86_64 arm64; do
        ARCH="$slice" "$0"
        for dir in vendor/llama.cpp vendor/whisper.cpp; do
            [ -d "$dir/build-static/bin" ] || continue
            for tool in llama-server llama-bench llama-perplexity whisper-cli whisper-server; do
                mv "$dir/build-static/bin/$tool" "$dir/build-static/bin/$tool.$slice" 2>/dev/null || true
            done
        done
    done
    for dir in vendor/llama.cpp vendor/whisper.cpp; do
        [ -d "$dir/build-static/bin" ] || continue
        for tool in llama-server llama-bench llama-perplexity whisper-cli whisper-server; do
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

# The shaders are always embedded, but compiling them at launch costs tens of seconds, so a
# precompiled default.metallib ships alongside and device.m prefers it on matching GPUs.
# Building it needs the Metal Toolchain from full Xcode, downloaded below if missing.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if ! xcrun metal -v >/dev/null 2>&1 || ! xcrun -f metallib >/dev/null 2>&1; then
    xcodebuild -downloadComponent MetalToolchain >/dev/null 2>&1 || true
fi
resolve_metal_toolchain() {
    # Resolve the demand-mounted toolchain before each shader build.
    xcrun metal -v >/dev/null 2>&1 || return 1
    METAL_COMPILER="$(xcrun -f metal 2>/dev/null)" || return 1
    METALLIB_COMPILER="$(xcrun -f metallib 2>/dev/null)" || return 1
    [ -x "$METAL_COMPILER" ] && [ -x "$METALLIB_COMPILER" ]
}

if resolve_metal_toolchain; then
    METAL_PRECOMPILE=1
    echo "Metal compiler available — will precompile default.metallib (fast model load)"
else
    METAL_PRECOMPILE=0
    echo "Metal compiler unavailable — embedded source only (slower first load)"
fi

# Stamped into the binaries so a log identifies the ToshLLM build, not just the
# upstream commit (which is unchanged across releases that only touch the patch).
TOSH_VERSION="$(tr -d '[:space:]' < "$(dirname "$0")/../VERSION")"

# CI runners drop DNS or reset a transfer now and then, and a release build should not lose
# minutes of compilation to it, so every networked git operation retries with backoff.
retry_git() {
    local attempt=1
    local max_attempts=4
    local delay

    while ! "$@"; do
        if [ "$attempt" -ge "$max_attempts" ]; then
            echo "ERROR: git operation failed after $max_attempts attempts: $*" >&2
            return 1
        fi
        delay=$((attempt * 10))
        echo "Git network operation failed (attempt $attempt/$max_attempts); retrying in ${delay}s..." >&2
        sleep "$delay"
        attempt=$((attempt + 1))
    done
}

CMAKE_FLAGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_SHARED_LIBS=OFF
    -DGGML_METAL=ON
    -DGGML_METAL_EMBED_LIBRARY=ON
    # Compile the experimental MoE cache into the bundled engine. It remains
    # inert unless the app explicitly sets TOSH_MOE_MODE at process launch.
    -DTOSH_ENABLE_DYNAMIC_MOE=ON
    -DGGML_NATIVE=OFF
    -DCMAKE_OSX_ARCHITECTURES="$ARCH"
    # cmake defaults it to the build host, so a macos-26 runner emits binaries dyld
    # refuses to start on older systems
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
    -DCMAKE_CXX_FLAGS="-DTOSH_VERSION=$TOSH_VERSION"
    # The server binds to localhost only; skip OpenSSL so static cross-builds
    # don't pick up host-arch Homebrew libraries on CI runners.
    -DLLAMA_OPENSSL=OFF
)

# pin every ISA flag: with GGML_NATIVE=OFF ggml's defaults follow the build host, and an
# arm64 runner cross-building x86_64 does not count as cross-compiling. TOSH_NO_AVX2=1 is
# the SSE4.2 baseline for pre-AVX Xeons.
ISA_FLAGS=()
if [ "$ARCH" = "x86_64" ]; then
    if [ -z "${TOSH_NO_AVX2:-}" ]; then
        ISA_FLAGS=(-DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON)
    else
        ISA_FLAGS=(-DGGML_SSE42=ON -DGGML_AVX=OFF -DGGML_AVX2=OFF -DGGML_FMA=OFF
                   -DGGML_F16C=OFF -DGGML_BMI2=OFF -DGGML_AVX_VNNI=OFF)
    fi
    CMAKE_FLAGS+=("${ISA_FLAGS[@]}")
fi

build_engine() {
    local vendor="$1" ref="$2" fetch_ref="$3"
    shift 3
    local patches=("$@")

    if [ ! -d "$vendor/.git" ]; then
        retry_git git clone --filter=blob:none https://github.com/ggml-org/llama.cpp "$vendor"
    fi
    cd "$vendor"
    retry_git git fetch origin "$fetch_ref" 2>/dev/null || retry_git git fetch origin
    git checkout -qf "$ref"
    git checkout -- . 2>/dev/null || true
    # files a patch creates are untracked, so the checkout above leaves them behind
    # and the next apply fails; build dirs are gitignored and survive this
    git clean -qfd 2>/dev/null || true

    for patch in "${patches[@]}"; do
        git apply "$patch"
        echo "applied ${patch#$ROOT/patches/}"
    done

    cmake -B build-static "${CMAKE_FLAGS[@]}"
    cmake --build build-static --config Release -j "$(sysctl -n hw.ncpu)" -t llama-server llama-bench llama-perplexity test-backend-ops

    # built from the merged source the embed step produces, with the same defines the runtime
    # would use on an Intel/AMD GPU, so device.m can load it instead of compiling
    local merged="build-static/ggml/src/ggml-metal/autogenerated/ggml-metal-embed.metal"
    if [ "$METAL_PRECOMPILE" = 1 ] && [ -f "$merged" ]; then
        if resolve_metal_toolchain && "$METAL_COMPILER" -O3 -mmacosx-version-min=14.0 -std=metal3.1 \
                -DGGML_METAL_EMBED_LIBRARY -DGGML_METAL_HAS_BF16 \
                -I ggml/src -I ggml/src/ggml-metal \
                -c "$merged" -o build-static/bin/ggml-metal.air &&
           "$METALLIB_COMPILER" build-static/bin/ggml-metal.air \
                -o build-static/bin/default.metallib; then
            rm -f build-static/bin/ggml-metal.air
            echo "precompiled default.metallib ($(du -h build-static/bin/default.metallib | cut -f1))"
        else
            rm -f build-static/bin/ggml-metal.air build-static/bin/default.metallib
            echo "WARNING: metallib precompile failed — falling back to runtime compile"
            # Avoid repeating a failed optional precompile.
            METAL_PRECOMPILE=0
        fi
    fi
    echo "engine ready at $PWD/build-static/bin (arch: $ARCH)"
    cd "$ROOT"
}

build_whisper_engine() {
    local vendor="vendor/whisper.cpp"
    if [ ! -d "$vendor/.git" ]; then
        retry_git git clone --filter=blob:none https://github.com/ggml-org/whisper.cpp "$vendor"
    fi
    cd "$vendor"
    retry_git git fetch origin "$WHISPER_COMMIT" 2>/dev/null || retry_git git fetch origin
    git checkout -qf "$WHISPER_COMMIT"
    git checkout -- . 2>/dev/null || true
    git clean -qfd 2>/dev/null || true

    # Reuse the llama AMD patches before applying Whisper-specific patches.
    for patch in "$ROOT"/patches/llama/metal/0001-*.patch; do
        [ -f "$patch" ] || continue
        git apply --include='ggml/src/ggml-metal/**' "$patch"
        echo "applied ${patch#$ROOT/patches/}"
    done
    for patch in "$ROOT"/patches/whisper/*.patch; do
        [ -f "$patch" ] || continue
        git apply "$patch"
        echo "applied ${patch#$ROOT/patches/}"
    done

    local isa=("${ISA_FLAGS[@]}")
    cmake -B build-static \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DWHISPER_BUILD_TESTS=OFF \
        -DWHISPER_BUILD_SERVER=ON \
        -DWHISPER_BUILD_EXAMPLES=ON \
        -DWHISPER_BUILD_IS_DEV=OFF \
        -DGGML_METAL=ON \
        -DGGML_METAL_EMBED_LIBRARY=ON \
        -DGGML_NATIVE=OFF \
        "${isa[@]}" \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
    cmake --build build-static --config Release -j "$(sysctl -n hw.ncpu)" -t whisper-cli whisper-server

    # Precompile Metal shaders for first use.
    local merged="build-static/ggml/src/ggml-metal/autogenerated/ggml-metal-embed.metal"
    if [ "$METAL_PRECOMPILE" = 1 ] && [ -f "$merged" ]; then
        if resolve_metal_toolchain && "$METAL_COMPILER" -O3 -mmacosx-version-min=14.0 -std=metal3.1 \
                -DGGML_METAL_EMBED_LIBRARY -DGGML_METAL_HAS_BF16 \
                -I ggml/src -I ggml/src/ggml-metal \
                -c "$merged" -o build-static/bin/ggml-metal.air &&
           "$METALLIB_COMPILER" build-static/bin/ggml-metal.air \
                -o build-static/bin/default.metallib; then
            rm -f build-static/bin/ggml-metal.air
            echo "precompiled default.metallib for speech engine"
        else
            rm -f build-static/bin/ggml-metal.air build-static/bin/default.metallib
            echo "WARNING: speech metallib precompile failed — using embedded source" >&2
            METAL_PRECOMPILE=0
        fi
    fi
    echo "speech-to-text engine ready at $PWD/build-static/bin (arch: $ARCH)"
    cd "$ROOT"
}

# stable-diffusion.cpp shares the ggml/Metal stack, so it takes the ggml-metal hunks of the
# 0001 series and nothing else; the llama half has no counterpart here.
build_image_engine() {
    local vendor="vendor/stable-diffusion.cpp"
    # `git clone --recursive` stalls on the ggml submodule fetch on flaky links;
    # clone the main repo, then init the submodule separately, both abort-and-retry
    # on a stalled transfer instead of hanging.
    if [ ! -d "$vendor/.git" ]; then
        retry_git env GIT_HTTP_LOW_SPEED_LIMIT=2000 GIT_HTTP_LOW_SPEED_TIME=30 \
            git clone https://github.com/leejet/stable-diffusion.cpp "$vendor"
    fi
    cd "$vendor"
    retry_git git fetch origin
    # the previous build left the patches in both working trees; a bump that moves the
    # submodule cannot check the new commit out over them, so revert before switching
    git -C ggml checkout -- . 2>/dev/null || true
    git checkout -- . 2>/dev/null || true
    git checkout -qf "$SD_COMMIT"
    git submodule sync --recursive
    retry_git env GIT_HTTP_LOW_SPEED_LIMIT=2000 GIT_HTTP_LOW_SPEED_TIME=30 \
        git submodule update --init --recursive
    git checkout -- . 2>/dev/null || true
    git -C ggml checkout -- . 2>/dev/null || true

    # impl.h needs -C2: this engine's decode N_R0/N_SG block differs from llama.cpp's, so a -U5
    # hunk finds no match. Safe only because every define it edits is unique, asserted below.
    # The 0001-* series is the shared Metal backend and is applied here **unchanged**, so any
    # improvement to it reaches this engine on its own. This ggml is older, and exactly four
    # hunks cannot land on it; they are applied from patches/image/0002 in their adapted form.
    # If that set ever changes, the build stops instead of shipping a backend missing a hunk.
    local expected_rejects="ggml-metal-device.cpp.rej ggml-metal-device.m.rej ggml-metal.cpp.rej ggml-metal.metal.rej"
    for shared in "$ROOT"/patches/llama/metal/0001-*.patch; do
        git apply --reject --exclude='ggml/src/ggml-metal/ggml-metal-impl.h' \
                  --include='ggml/src/ggml-metal/*' -p1 "$shared" >/dev/null 2>&1 || true
    done
    local got_rejects
    got_rejects=$(find ggml/src/ggml-metal -name '*.rej' -exec basename {} \; | sort -u | tr '\n' ' ')
    got_rejects="${got_rejects% }"
    if [ "$got_rejects" != "$expected_rejects" ]; then
        echo "ERROR: the shared Metal series no longer diverges where patches/image/0002 expects." >&2
        echo "  expected rejects: $expected_rejects" >&2
        echo "  got:              $got_rejects" >&2
        echo "  inspect the .rej files, then update patches/image/0002-image-metal-divergent-hunks.patch" >&2
        exit 1
    fi
    find ggml/src/ggml-metal \( -name '*.rej' -o -name '*.orig' \) -delete
    git apply --include='ggml/src/ggml-metal/*' -p1 \
              "$ROOT/patches/image/0002-image-metal-divergent-hunks.patch"
    git apply --include='ggml/src/ggml-metal/ggml-metal-impl.h' -C2 -p1 \
              "$ROOT/patches/llama/metal/0001-7-metal-backend-host.patch"
    git apply --include='ggml/src/ggml-metal/*' -p1 "$ROOT/patches/image/0003-image-metal-ncb.patch"
    # sd.cpp core (outside the ggml submodule): per-op CPU fallback for wave64.
    git apply -p1 "$ROOT/patches/image/0004-image-cpu-fallback-sched.patch"
    git apply -p1 "$ROOT/patches/image/0008-image-ext-wave64.patch"
    # after 0008: both edit ggml-metal.metal and ggml-metal-ops.cpp, and 0021 was
    # generated on top of it. Without a Metal im2col_3d, ggml_conv_3d falls back to
    # the direct 3D convolution, slow enough that the Wan VAE trips the watchdog.
    git apply --include='ggml/src/ggml-metal/*' -p1 "$ROOT/patches/image/0021-image-metal-im2col-3d.patch"
    # UNet head sizes for the AMD flash-attention kernels: SD 1.5 builds a 2.7 GB score
    # matrix at 768 and does not fit at all at 1024 without them. Image-side copy because
    # this engine's .metal spells the wave64 instantiation macro differently.
    git apply --include='ggml/src/ggml-metal/*' -p1 "$ROOT/patches/image/0047-image-fa-unet-heads.patch"
    # Release diffusion weights before video decoding.
    git apply -p1 "$ROOT/patches/image/0049-image-free-diffusion-before-video-decode.patch"
    # Yield between VAE tiles to keep the desktop responsive.
    git apply -p1 "$ROOT/patches/image/0050-image-vae-tile-yield.patch"
    # Read tensors with pread: stdio refills 4 KiB at a time and the load ran at a tenth
    # of what the disk gives.
    git apply -p1 "$ROOT/patches/image/0051-image-loader-pread.patch"
    echo "applied ggml-metal hunks of 0001 + 0003 + core fallback 0004 + ext wave64 0008 to stable-diffusion.cpp"

    # This ggml is on a different commit, so an ambiguous hunk can land on the wrong
    # function and still exit 0. Patch context is -U5 to avoid it; assert it anyway.
    local metal="ggml/src/ggml-metal/ggml-metal.metal"
    if ! awk '/^kernel void kernel_cumsum_blk\(/,/\{$/' "$metal" | grep -q 'sgptg\[\[threads_per_simdgroup\]\]'; then
        echo "ERROR: patch 0001 landed wrong in $metal (kernel_cumsum_blk lost its sgptg parameter)" >&2
        exit 1
    fi
    # the reduced-context pass above must still land the fields the AMD kernels read
    local impl="ggml/src/ggml-metal/ggml-metal-impl.h"
    if ! awk '/ggml_metal_kargs_flash_attn_ext_vec;/{exit} {print}' "$impl" | grep -q 'int32_t  has_mask;'; then
        echo "ERROR: patch 0001 landed wrong in $impl (flash_attn_ext_vec lost has_mask)" >&2
        exit 1
    fi

    local isa=("${ISA_FLAGS[@]}")
    cmake -B build-static \
        -DCMAKE_BUILD_TYPE=Release \
        -DSD_METAL=ON \
        -DGGML_METAL_EMBED_LIBRARY=ON \
        -DGGML_NATIVE=OFF \
        "${isa[@]}" \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
    cmake --build build-static --config Release -j "$(sysctl -n hw.ncpu)" -t sd-cli

    local merged="build-static/ggml/src/ggml-metal/autogenerated/ggml-metal-embed.metal"
    if [ "$METAL_PRECOMPILE" = 1 ] && [ -f "$merged" ]; then
        if resolve_metal_toolchain && "$METAL_COMPILER" -O3 -mmacosx-version-min=14.0 -std=metal3.1 \
                -DGGML_METAL_EMBED_LIBRARY -DGGML_METAL_HAS_BF16 \
                -I ggml/src -I ggml/src/ggml-metal \
                -c "$merged" -o build-static/bin/ggml-metal.air &&
           "$METALLIB_COMPILER" build-static/bin/ggml-metal.air \
                -o build-static/bin/default.metallib; then
            rm -f build-static/bin/ggml-metal.air
            echo "precompiled default.metallib for image engine"
        else
            rm -f build-static/bin/ggml-metal.air build-static/bin/default.metallib
            # Embedded source remains available for runtime compilation.
            echo "WARNING: image metallib precompile failed — using embedded source" >&2
            METAL_PRECOMPILE=0
        fi
    fi
    echo "image engine ready at $PWD/build-static/bin (arch: $ARCH)"
    cd "$ROOT"
}

# Patches live in patches/<engine>/<area>/, and the numeric prefix is the apply order across
# every area, so ordering stays global while each area can be regenerated on its own.
patch_series() {
    find "$ROOT/patches/$1" -name '*.patch' -print |
        awk -F/ '{print $NF"\t"$0}' | sort | cut -f2-
}

# 1. Official engine (skip with SKIP_LLAMA=1 when iterating on the image engine)
if [ -z "$SKIP_LLAMA" ]; then
build_engine vendor/llama.cpp "$LLAMA_COMMIT" "$LLAMA_COMMIT" ${(f)"$(patch_series llama)"}
fi

# 2. Speech-to-text engine (skip with SKIP_WHISPER=1)
if [ -z "$SKIP_WHISPER" ]; then
    build_whisper_engine
fi


# 3. Image engine (stable-diffusion.cpp; skip with SKIP_IMAGE=1)
if [ -z "$SKIP_IMAGE" ]; then
    build_image_engine
fi
