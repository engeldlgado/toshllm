#!/bin/sh
# Starts the ToshLLM engine with the settings measured on this machine: RX 580 (gfx803)
# through the Bronze-patched Metal driver, Metal 2.4, macOS 12.
# Usage: ./start.sh /path/to/model.gguf [extra llama-server arguments]
# Optional: CTX (context, 8192), PORT (8080), HOST (0.0.0.0), NCMOE (MoE layers on the CPU),
#           UB/B (ubatch/batch, default chosen from CTX), CTK/CTV (KV types, q4_0),
#           FA (flash attn, on), NGL (`fit` by default, or a number), NP (slots, engine default).
set -e
cd "$(dirname "$0")"

if [ -z "$1" ] || [ ! -f "$1" ]; then
    echo "usage: ./start.sh /path/to/model.gguf [extra llama-server arguments]"
    exit 1
fi
MODEL="$1"
shift

# the AMD attention kernels are off unless asked for
export TOSH_FA_AMD=1

# with experts on the CPU, prefetching them keeps prompt reading on the GPU path
if [ -n "$NCMOE" ]; then
    export GGML_SCHED_PREFETCH_EXPERTS=1 GGML_CPU_NO_REPACK=1
    set -- --n-cpu-moe "$NCMOE" "$@"
fi

CTX=${CTX:-8192}
case "$CTX" in ''|*[!0-9]*) CTX=8192 ;; esac

# -ub/-b size the prefill compute buffers, and those buffers also grow with the context, so a
# fixed -ub 2048 asks for 6048 MiB of MTL0_Private at CTX 48192 (measured: "failed to allocate
# buffer, size = 6048.00 MiB", model never loads) while 1024 and 512 load the same model.
# Anchors on the 8 GB card: 8192@2048 ok, 32768@2048 fails, 48192@1024 ok, 68192@512 ok.
if [ -z "$UB" ]; then
    if [ "$CTX" -le 16384 ]; then UB=2048
    elif [ "$CTX" -le 49152 ]; then UB=1024
    else UB=512
    fi
fi
if [ -z "$B" ]; then B=$((UB * 2)); fi

CTK=${CTK:-q4_0}; CTV=${CTV:-q4_0}; FA=${FA:-on}
HOST=${HOST:-0.0.0.0}

# NGL=99 keeps every layer on the GPU, which is what the measured numbers were taken with.
# NGL=fit hands the layer count to the engine (--fit on) instead: it never fails the way a
# fixed -ngl does once the weights no longer fit beside the KV cache and the compute buffers
# ("Metal can't allocate"), but it silently leaves layers on the CPU, i.e. no GPU use at all
# for a model that does not fit, which is worse than an error. Use it only as the fallback
# for a model larger than the card.
NGL=${NGL:-99}
if [ "$NGL" = "fit" ]; then GL_ARGS="--fit on"; else GL_ARGS="-ngl $NGL"; fi

NP_ARGS=""
[ -n "$NP" ] && NP_ARGS="--parallel $NP"

# EXTRA passes further llama-server flags through one variable, so callers that can only
# set the environment (gm.sh, the app launcher) do not need a second entry point.
EXTRA=${EXTRA:-}

# the installed engine is the one that gets rebuilt; a shipped zip has no /usr/local copy
SRV=/usr/local/bin/llama-server
[ -x "$SRV" ] || SRV=./bin/llama-server

echo "Serving on ${HOST}:${PORT:-8080} (this machine: http://$(ipconfig getifaddr en0 2>/dev/null || echo 127.0.0.1):${PORT:-8080}), ctx $CTX, ub $UB, b $B, layers $NGL"
exec "$SRV" -m "$MODEL" $GL_ARGS -c "$CTX" -fa "$FA" $NP_ARGS \
    --load-mode none --jinja --no-reasoning-preserve --cache-ram 2048 \
    --host "$HOST" --port "${PORT:-8080}" --path web-ui \
    -ub "$UB" -b "$B" -ctk "$CTK" -ctv "$CTV" $EXTRA "$@"
