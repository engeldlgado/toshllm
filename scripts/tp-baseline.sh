#!/bin/zsh
# Baseline: 4× W6800X Duo dies, dense GLM-4-9B-Q4_K_M, tensor parallelism.
# Same bench parameters as scripts/mgpu-report.sh so results stay comparable.
#
#   ./scripts/tp-baseline.sh [out-dir]
#
# Device topology on this machine (ggml enumeration order):
#   dev 0  RX 6900 XT        peer group 0  (display GPU, never in the split)
#   dev 1-4 W6800X Duo dies  peer group 5545434699043849590 (one hive, bridged)
#   Adjacent indices are the two dies of one module: {1,2} = Slot-1, {3,4} = Slot-3
#   (verified with system_profiler SPDisplaysDataType slot fields). A TP2 pair on
#   adjacent indices crosses only the jumper; 1,3 crosses the bridge.
#
# Env: ONLY=comma,separated,names  run just those configs (e.g. ONLY=tp2_jumper,tp2_bridge)
#      TOSH_MODEL_DRAFT=path.gguf   enables the speculative-decode rows (llama-cli)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/vendor/llama.cpp/build-static/bin/llama-bench"
SERVER="$ROOT/vendor/llama.cpp/build-static/bin/llama-server"
MODEL="${TOSH_MODEL:-$HOME/models/GLM-4-9B-0414-Q4_K_M.gguf}"
OUT="${1:-$ROOT/.bench/tp-baseline-2026-09-11}"
mkdir -p "$OUT"

[ -x "$BIN" ] || { echo "llama-bench not found at $BIN" >&2; exit 1; }
[ -f "$MODEL" ] || { echo "model not found at $MODEL" >&2; exit 1; }

export GGML_METAL_DEVICE_LIST=1,2,3,4
export GGML_METAL_SHARED_BUFFERS_DISABLE=1
export GGML_METAL_CONCURRENCY_DISABLE=1
export TOSH_FA_AMD=1

BENCH=(-m "$MODEL" -ngl 99 -fa 1 --load-mode none -p 512 -n 128 -r 2)

# run <name> [VAR=1 ...] -- <llama-bench split flags ...>
run() {
    local name=$1; shift
    local envs=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done; shift
    if [[ -n "${ONLY:-}" && ",${ONLY}," != *",${name},"* ]]; then
        echo "=== $name (skipped, ONLY=$ONLY)"; return
    fi
    echo "=== $name (${envs[*]:-} $*)"
    env -u TOSH_MGPU_PEER -u TOSH_MGPU_EVENTS -u TOSH_MGPU_TENSOR_GROUP \
        -u TOSH_MGPU_HIERARCHICAL -u TOSH_MGPU_STAGE_F16 -u TOSH_MGPU_ONESHOT \
        -u TOSH_MGPU_COMM_PARALLEL \
        "${envs[@]}" "$BIN" "${BENCH[@]}" "$@" > "$OUT/$name.log" 2>&1
    grep -E "\| *pp512|\| *tg128|Infinity Fabric|cross-device hand-off|grouping|reducing across" \
        "$OUT/$name.log" | head -8
}

# single-die reference; every decode row should be judged against this one, in-run
run solo     GGML_METAL_DEVICE_LIST=1               -- -sm none

run tp_prod    TOSH_MGPU_PEER=1 TOSH_MGPU_EVENTS=1 -- -sm tensor
run tp_events  TOSH_MGPU_EVENTS=1                   -- -sm tensor
run tp_none                                         -- -sm tensor
run tp_group2  TOSH_MGPU_PEER=1 TOSH_MGPU_EVENTS=1 TOSH_MGPU_TENSOR_GROUP=2 -- -sm tensor
run layer_ref                                       -- -sm layer

# The jumper-vs-bridge question. Same TP2 shape twice; only the crossing differs.
# Per-reduction cost is ~175 us on the bridged hive; if the intra-module pair lands
# materially below that, the sync tax is a bridge cost and TP2-within-a-Duo can beat
# solo decode (it needs < ~96 us/reduction to do so on GLM-4-9B).
run tp2_jumper  TOSH_MGPU_PEER=1 TOSH_MGPU_EVENTS=1 GGML_METAL_DEVICE_LIST=1,2 -- -sm tensor
run tp2_bridge  TOSH_MGPU_PEER=1 TOSH_MGPU_EVENTS=1 GGML_METAL_DEVICE_LIST=1,3 -- -sm tensor

# repeat the production config last, to see run-to-run drift over the session
run tp_prod2   TOSH_MGPU_PEER=1 TOSH_MGPU_EVENTS=1 -- -sm tensor

# Speculative decode. The per-token sync tax (80 collectives on TP4) is paid once per
# TARGET forward pass, so every accepted draft token amortizes it. llama-completion in
# this tree cannot drive speculation at all: the --spec args are set_examples()
# server/speculative-simple/cli and it never calls common_speculative, so these rows drive
# llama-server and read its per-request timings. ngram-* is draft-LESS - the host ngram
# lookup costs no GPU step at all, which is exactly what a host-bound TP decode wants.
# TOSH_MODEL_DRAFT=<same-vocab gguf> adds one model-draft row (--spec-draft-model).
spec_matrix() {
# run_spec <name> [VAR=1 ...] -- <extra llama-server flags ...>
local PORT=8190
run_spec() {
    local name=$1; shift
    local envs=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done; shift
    if [[ -n "${ONLY:-}" && ",${ONLY}," != *",${name},"* ]]; then
        echo "=== $name (skipped, ONLY=$ONLY)"; return
    fi
    local port=$((PORT++))
    echo "=== $name (${envs[*]:-} $*)"
    env -u TOSH_MGPU_PEER -u TOSH_MGPU_EVENTS -u TOSH_MGPU_TENSOR_GROUP \
        -u TOSH_MGPU_HIERARCHICAL -u TOSH_MGPU_STAGE_F16 -u TOSH_MGPU_ONESHOT \
        -u TOSH_MGPU_COMM_PARALLEL \
        "${envs[@]}" "$SERVER" -m "${SPEC_MODEL:-$MODEL}" -ngl 99 -fa 1 --load-mode none \
        -c 2048 -np 1 --port "$port" "$@" > "$OUT/$name.log" 2>&1 &
    local pid=$! i=0
    while (( i++ < 150 )); do curl -sf "http://127.0.0.1:$port/health" >/dev/null 2>&1 && break; sleep 2; done
    # Warm up with DIFFERENT filler text. Warming with the measured prompt makes the greedy
    # output repeat itself and ngram acceptance hits 1.0 (mean len ~65) - degenerate, not a
    # baseline. One timed pass of the real prompt afterwards.
    curl -s "http://127.0.0.1:$port/completion" \
        -d '{"prompt":"Warm-up pass; this sentence is unrelated filler.","n_predict":32,"temperature":0,"ignore_eos":true}' >/dev/null
    curl -s "http://127.0.0.1:$port/completion" \
        -d "{\"prompt\":\"$SPEC_PROMPT\",\"n_predict\":128,\"temperature\":0,\"ignore_eos\":true}" \
    | python3 -c 'import json,sys; t=json.load(sys.stdin)["timings"]; print("tg:", round(1000.0*t["predicted_n"]/t["predicted_ms"],2), "tok/s")'
    kill $pid 2>/dev/null; wait $pid 2>/dev/null
    grep -E 'draft acceptance|Infinity Fabric' "$OUT/$name.log" | tail -3
    sleep 3
}
run_spec spec_solo_none  GGML_METAL_DEVICE_LIST=1                                 -- -sm none
run_spec spec_solo_ngram GGML_METAL_DEVICE_LIST=1                                 -- -sm none --spec-type ngram-mod --spec-draft-n-max 4
run_spec spec_tp2_none   TOSH_MGPU_PEER=1 TOSH_MGPU_EVENTS=1 GGML_METAL_DEVICE_LIST=1,2 -- -sm tensor
run_spec spec_tp2_ngram  TOSH_MGPU_PEER=1 TOSH_MGPU_EVENTS=1 GGML_METAL_DEVICE_LIST=1,2 -- -sm tensor --spec-type ngram-mod --spec-draft-n-max 4
run_spec spec_tp4_none   TOSH_MGPU_PEER=1 TOSH_MGPU_EVENTS=1                      -- -sm tensor
run_spec spec_tp4_ngram  TOSH_MGPU_PEER=1 TOSH_MGPU_EVENTS=1                      -- -sm tensor --spec-type ngram-mod --spec-draft-n-max 4
if [[ -n "${TOSH_MODEL_DRAFT:-}" ]]; then
    run_spec spec_tp4_draft TOSH_MGPU_PEER=1 TOSH_MGPU_EVENTS=1                   -- -sm tensor \
        --spec-type draft-simple --spec-draft-model "$TOSH_MODEL_DRAFT"
fi

# dflash draft-head rows: the fork's native draft path, and the only model on this box with
# a real sidecar (Qwen3.6-35B-A3B + 421 MB .dflash.gguf, matching vocab). Mechanism test
# for the k-amortization claim on TP4, since no same-vocab small draft exists for GLM-4-9B.
# SOLO Qwen rows deliberately omitted: 20.9 GiB does not fit one die -> CPU-offloaded decode
# at ~2.2 t/s AND a ~16 min stall in early init before load_model even starts (observed
# 2026-09-16). The comparison that answers the question is TP4 none-vs-dflash.
QWEN="${TOSH_MODEL_QWEN:-$HOME/models/Qwen3.6-35B-A3B-UD-Q4_K_S.gguf}"
DFLASH="${QWEN%.gguf}.dflash.gguf"
if [[ -f "$QWEN" && -f "$DFLASH" ]]; then
    SPEC_MODEL="$QWEN"
    run_spec spec_qwen_tp4_none    TOSH_MGPU_PEER=1 TOSH_MGPU_EVENTS=1            -- -sm tensor
    run_spec spec_qwen_tp4_dflash  TOSH_MGPU_PEER=1 TOSH_MGPU_EVENTS=1            -- -sm tensor \
        --spec-type draft-dflash --spec-draft-model "$DFLASH"
    unset SPEC_MODEL
fi
}
# spec rows only when explicitly requested (they restart the server per row, ~40 s each)
if [[ -n "${SPEC:-}" ]]; then
    SPEC_PROMPT="Explain in one paragraph why memory bandwidth dominates single-stream decode."
    spec_matrix
fi
echo "=== done (logs in $OUT)"
