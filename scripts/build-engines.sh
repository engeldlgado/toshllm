#!/bin/zsh
# Builds the inference engines reproducibly:
#   1. Official llama.cpp + AMD patches  -> vendor/llama.cpp/build-static/bin
#   2. TurboQuant engine (llama.cpp PR 23962 + repair patches, optional)
#                                        -> vendor/llama.cpp-turbo/build-static/bin
#
# Usage:
#   ./scripts/build-engines.sh                  # host architecture, both engines
#   ARCH=x86_64 ./scripts/build-engines.sh      # cross-compile (CI on arm64 runners)
#   SKIP_TURBO=1 ./scripts/build-engines.sh     # official engine only
set -e
cd "$(dirname "$0")/.."
ROOT="$PWD"

LLAMA_COMMIT="${LLAMA_COMMIT:-1593d56}"   # llama.cpp commit validated against the patches
TURBO_COMMIT="${TURBO_COMMIT:-a3e3638}"   # head of llama.cpp PR 23962 (TurboQuant KV cache)
ARCH="${ARCH:-$(uname -m)}"

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
    echo "engine ready at $PWD/build-static/bin (arch: $ARCH)"
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
