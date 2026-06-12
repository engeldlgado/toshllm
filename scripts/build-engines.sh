#!/bin/zsh
# Builds the inference engine (llama.cpp + AMD patches) reproducibly.
# Output: vendor/llama.cpp/build-static/bin/{llama-server,llama-bench}
#
# Usage:
#   ./scripts/build-engines.sh                  # host architecture
#   ARCH=x86_64 ./scripts/build-engines.sh      # cross-compile (CI on arm64 runners)
set -e
cd "$(dirname "$0")/.."

LLAMA_COMMIT="${LLAMA_COMMIT:-1593d56}"   # llama.cpp commit validated against the patches
ARCH="${ARCH:-$(uname -m)}"
VENDOR="vendor/llama.cpp"

if [ ! -d "$VENDOR/.git" ]; then
    git clone --filter=blob:none https://github.com/ggml-org/llama.cpp "$VENDOR"
fi
cd "$VENDOR"
git fetch --depth 1 origin "$LLAMA_COMMIT" 2>/dev/null || git fetch origin
git checkout -q "$LLAMA_COMMIT"

# Patch: chunked staging transfers for AMD drivers that cap host-visible
# allocations (required on discrete AMD GPUs).
git checkout -- ggml/src/ggml-metal/ggml-metal-device.m 2>/dev/null || true
git apply ../../patches/0001-metal-amd-staging-transfers.patch
echo "AMD patch applied"

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

cmake -B build-static "${CMAKE_FLAGS[@]}"
cmake --build build-static --config Release -j "$(sysctl -n hw.ncpu)" -t llama-server llama-bench

echo "engines ready at $PWD/build-static/bin (arch: $ARCH)"
