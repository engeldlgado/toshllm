#!/bin/zsh
# Builds the inference engines reproducibly:
#   1. Official llama.cpp + AMD patches  -> vendor/llama.cpp/build-static/bin
#
# Usage:
#   ./scripts/build-engines.sh                  # host architecture
#   ARCH=x86_64 ./scripts/build-engines.sh      # cross-compile (CI on arm64 runners)
#   ARCH=universal ./scripts/build-engines.sh   # x86_64 + arm64 fat binaries (experimental)
set -e
cd "$(dirname "$0")/.."
ROOT="$PWD"

LLAMA_COMMIT="${LLAMA_COMMIT:-84e908c62}"   # llama.cpp commit validated against the patches
SD_COMMIT="${SD_COMMIT:-de298c2}"         # stable-diffusion.cpp commit validated for image gen
ARCH="${ARCH:-$(uname -m)}"
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
export MACOSX_DEPLOYMENT_TARGET
if [ "$ARCH" = "universal" ]; then
    # Build each slice separately (ggml has per-arch sources) and lipo them.
    for slice in x86_64 arm64; do
        ARCH="$slice" "$0"
        for dir in vendor/llama.cpp; do
            [ -d "$dir/build-static/bin" ] || continue
            for tool in llama-server llama-bench llama-perplexity; do
                mv "$dir/build-static/bin/$tool" "$dir/build-static/bin/$tool.$slice" 2>/dev/null || true
            done
        done
    done
    for dir in vendor/llama.cpp; do
        [ -d "$dir/build-static/bin" ] || continue
        for tool in llama-server llama-bench llama-perplexity; do
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

check_macos_target() {
    local bin="$1"
    local minos
    minos="$(otool -l "$bin" | awk '$1 == "minos" { print $2; exit }')"
    if [ -z "$minos" ]; then
        echo "ERROR: could not read the macOS deployment target from $bin" >&2
        return 1
    fi
    if [ "$minos" != "$MACOSX_DEPLOYMENT_TARGET" ]; then
        echo "ERROR: $bin targets macOS $minos, expected $MACOSX_DEPLOYMENT_TARGET" >&2
        return 1
    fi
    echo "verified $bin targets macOS $minos"
}

CMAKE_FLAGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_SHARED_LIBS=OFF
    -DGGML_METAL=ON
    -DGGML_METAL_EMBED_LIBRARY=ON
    -DGGML_NATIVE=OFF
    -DCMAKE_OSX_ARCHITECTURES="$ARCH"
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET"
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
    cmake --build build-static --config Release -j "$(sysctl -n hw.ncpu)" -t llama-server llama-bench llama-perplexity
    for tool in llama-server llama-bench llama-perplexity; do
        check_macos_target "build-static/bin/$tool"
    done

    # built from the merged source the embed step produces, with the same defines the runtime
    # would use on an Intel/AMD GPU, so device.m can load it instead of compiling
    local merged="build-static/ggml/src/ggml-metal/autogenerated/ggml-metal-embed.metal"
    if [ "$METAL_PRECOMPILE" = 1 ] && [ -f "$merged" ]; then
        if xcrun -sdk macosx metal -O3 -mmacosx-version-min=14.0 -std=metal3.1 \
                -DGGML_METAL_EMBED_LIBRARY -DGGML_METAL_HAS_BF16 \
                -I ggml/src -I ggml/src/ggml-metal \
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
    # the 0001-* series is the shared Metal backend; this engine takes only its ggml-metal hunks
    for shared in "$ROOT"/patches/llama/metal/0001-*.patch; do
        git apply --exclude='ggml/src/ggml-metal/ggml-metal-impl.h' \
                  --include='ggml/src/ggml-metal/*' -p1 "$shared"
    done
    git apply --include='ggml/src/ggml-metal/ggml-metal-impl.h' -C2 -p1 \
              "$ROOT/patches/llama/metal/0001-7-metal-backend-host.patch"
    git apply --include='ggml/src/ggml-metal/*' -p1 "$ROOT/patches/image/0003-image-metal-ncb.patch"
    # sd.cpp core (outside the ggml submodule): per-op CPU fallback for wave64.
    git apply -p1 "$ROOT/patches/image/0004-image-cpu-fallback-sched.patch"
    git apply -p1 "$ROOT/patches/image/0008-image-ext-wave64.patch"
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
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET"
    cmake --build build-static --config Release -j "$(sysctl -n hw.ncpu)" -t sd-cli
    check_macos_target build-static/bin/sd-cli

    local merged="build-static/ggml/src/ggml-metal/autogenerated/ggml-metal-embed.metal"
    if [ "$METAL_PRECOMPILE" = 1 ] && [ -f "$merged" ]; then
        if xcrun -sdk macosx metal -O3 -mmacosx-version-min=14.0 -std=metal3.1 \
                -DGGML_METAL_EMBED_LIBRARY -DGGML_METAL_HAS_BF16 \
                -I ggml/src -I ggml/src/ggml-metal \
                -c "$merged" -o build-static/bin/ggml-metal.air &&
           xcrun -sdk macosx metallib build-static/bin/ggml-metal.air \
                -o build-static/bin/default.metallib; then
            rm -f build-static/bin/ggml-metal.air
            echo "precompiled default.metallib for image engine"
        else
            rm -f build-static/bin/ggml-metal.air build-static/bin/default.metallib
            # a compile error here means our hunks landed wrong in the older ggml of
            # sd.cpp, which would also break the runtime compile
            echo "ERROR: image engine shaders do not compile" >&2
            exit 1
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


# 3. Image engine (stable-diffusion.cpp; skip with SKIP_IMAGE=1)
if [ -z "$SKIP_IMAGE" ]; then
    build_image_engine
fi
