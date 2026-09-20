# Ternary Bonsai 2 27B

Prism ML's Ternary Bonsai 2 27B is Qwen3.8-27B (the `qwen35` architecture: 48 GatedDeltaNet
layers and 16 full attention layers) with every projection, the embeddings and the output head
stored as ternary weights in a rotated basis. It ships as two GGUF packings of the same weights,
and both run on the GPU with patches `0079` and `0080` of `patches/llama/`.

| Packing | ggml type | Block | Bytes per block | Bits per weight | File |
|---|---|---|---|---|---|
| PQ2_0 | 142 | 128 | 34: fp16 scale and 2 bits per weight | 2.13 | 7.21 GB |
| PTQ1_0 | 143 | 128 | 28: base-3 trits, 5 per byte, and an fp16 scale | 1.75 | 5.95 GB |

The two decode to the same values, and they give the same perplexity to five digits.

## How the format is recognized

A file is a Prism ML ternary model when its tensors use type 142 or 143, and it is a rotated one
when it carries `prism.hadamard.version = 1`. The rest of the contract is read and checked at load:
block size (1024 here), transform (`normalized-sylvester-walsh-hadamard`), axis
(`input-last-dimension`), sign mode (`explicit`, one ±1 vector per input width: 5120, 6144 and
17408), the list of folded weights (401), the inverse table (`token_embd.weight`) and
`gdn_v_grouped`. Anything outside that contract stops the load with a message naming the key,
because a model that loads without its transform answers with fluent nonsense. The file type
field is 141 for PQ2_0 (142 in files packed before Prism renamed it) and 143 for PTQ1_0; the app
labels all three.

## What runs where

A folded weight W' was stored so that W·x = W'·H·(s·P·x), with H the blockwise Hadamard, s the
sign vector and P the head regrouping (identity except on `ssm_out`). Each matmul against it
therefore has to see H·(s·P·x) instead of x:

- `build_lora_mm` and `build_lora_mm_id` apply the transform to the activation of every folded
  weight. Weights that read the same activation (q, k, v and the GDN gate; ffn gate and up) share
  one transform.
- The embedding lookup applies the inverse, s·(H·z), to the rows it reads.
- `ssm_out` first regroups the GDN value heads from `[hd, nk, rep]` to `[hd, rep, nk]`.
- DFlash, DSpark and EAGLE3 drafts that borrow the target's embeddings or output head apply the
  target's transforms too. Without that a draft would propose noise and accept nothing.
- The first graph a context reserves is checked: every folded weight must consume a transform and
  every lookup from the rotated table must get the inverse, or the context refuses to start.

On Metal the sign flip, the head regrouping and the FWHT run as one kernel. A 1024-wide row is
spread over 128 threads: the lane bits and the per-thread bits transform in registers, and one
pass through threadgroup memory covers the rest. On the RX 6700 XT, PQ2_0 generates 31.56 tokens a
second with the transform skipped. Unfused, the transform brought that down to 29.24 (7.4% slower).
Fused, it gives 30.25 (4.2% slower).

Weights stay packed in VRAM. Prompts go through ToshGEMM, with the wide tile on both widths. Its
PQ2_0 dequantization writes each 2-bit field into the mantissa of 1024.0h, so 16 weights cost
eight `v_and_or` and sixteen packed half operations. Generation uses dedicated mat-vec kernels:
PQ2_0 isolates one field of four bytes with a `0x03030303` mask and converts each byte straight to
float; PTQ1_0 reads each packed byte once and looks its five trits up in a 256-entry table in
threadgroup memory. Batches of two to eight tokens, as speculative verification sends them, have
their own kernels that decode each weight once for every token.

## Correctness

The reference is Prism's own build (`PrismML-Eng/llama.cpp`, branch `prism`, commit `9a9394a8`)
on the same card and the same files: `llama-perplexity --kl-divergence`, 8 chunks of 512 tokens of
English prose and code.

| Card | Packing | Flash attention | Mean KLD | Max KLD | Same top token | PPL (Prism 4.3945) |
|---|---|---|---|---|---|---|
| RX 6700 XT | PQ2_0 | off | 0.000001 | 0.000043 | 100.00% | 4.3945 |
| RX 6700 XT | PQ2_0 | on | 0.000002 | 0.000056 | 99.90% | 4.3944 |
| RX 6700 XT | PTQ1_0 | on | 0.000002 | 0.000083 | 99.90% | 4.3944 |
| Pro Vega II Duo | PQ2_0 | on | 0.000003 | 0.000204 | 99.95% | 4.3942 |
| Pro Vega II Duo | PTQ1_0 | on | 0.000003 | 0.000198 | 99.95% | 4.3942 |

The Vega rows use the RX 6700 XT reference: Prism's build returns `nan` perplexity and a string of
commas on that card. Greedy generation of 732 tokens (arithmetic reasoning and a short story) is
byte for byte the same as Prism's on the RX 6700 XT, and ends on its own. The image description
through the Q8_0 vision projector is also byte for byte Prism's. The operator suite passes on both
cards, and Metal API validation reports nothing over a prompt and a generation of each packing.

Models already supported give the same perplexity to the last digit with and without the patches:
Qwen3.5-9B Q4_K_M, Qwen3-8B Q4_K_M, Qwen3-4B Q4_0 and Ternary-Bonsai-1.7B Q2_0.

## Speed

`llama-bench -r 3`, flash attention on, model held in memory (`-lm none`). Prism with
`GGML_METAL_CONCURRENCY_DISABLE=1`, which it needs on AMD, and flash attention off, since its
Metal build has none for these cards. "First port" is the straight port before any tuning.

Radeon RX 6700 XT, tokens a second:

| | pp512 | pp1024 | pp2048 | tg128 |
|---|---|---|---|---|
| PQ2_0, ToshLLM | **258.1** | 256.1 | 253.3 | **33.35** |
| PQ2_0, first port | 221.9 | 219.9 | 218.3 | 29.23 |
| PQ2_0, Prism | 59.3 | 58.7 | 57.7 | 24.80 |
| PTQ1_0, ToshLLM | **235.8** | 234.6 | 232.5 | **33.08** |
| PTQ1_0, Prism | 40.7 | 40.4 | 39.9 | 23.72 |

Radeon Pro Vega II Duo, one die (Prism does not run there: `nan` perplexity):

| | pp512 | pp1024 | pp2048 | tg128 |
|---|---|---|---|---|
| PQ2_0, ToshLLM | **203.6** | 202.1 | 200.8 | **36.94** |
| PQ2_0, first port | 169.5 | 168.6 | 167.5 | 28.54 |
| PTQ1_0, ToshLLM | **184.5** | 183.1 | 182.1 | **27.34** |
| PTQ1_0, first port | 126.0 | 125.6 | 124.9 | 23.07 |

From the first port to the final build, with every change below applied:

| Card | Packing | pp512 | tg128 |
|---|---|---|---|
| RX 6700 XT | PQ2_0 | 221.9 to 258.1, +16.3% | 29.23 to 33.35, +14.1% |
| Pro Vega II Duo | PQ2_0 | 169.5 to 203.6, +20.1% | 28.54 to 36.94, +29.4% |
| Pro Vega II Duo | PTQ1_0 | 126.0 to 184.5, +46.5% | 23.07 to 27.34, +18.5% |

There is no first-port row for PTQ1_0 on the RX 6700 XT, because its first mat-vec was replaced
before a full run. Against Prism on the RX 6700 XT, generation is 34.5% faster in PQ2_0
(24.80 to 33.35) and 39.5% faster in PTQ1_0 (23.72 to 33.08).

On the same Vega die Qwen3.8-27B, the same architecture, runs in Q4_0 at 191.4 and 25.9 with these
patches (160.9 and 23.8 without them), so Bonsai is faster than the conventional quantizations of
its base on both counts.

Memory on the RX 6700 XT, from the engine's own breakdown, KV cache in f16:

| Packing | 4K context | 32K context |
|---|---|---|
| PQ2_0 | 7.35 GiB | 9.21 GiB |
| PTQ1_0 | 6.24 GiB | 8.10 GiB |

The token embedding table (322 MiB) stays in system memory, as it does for every model; the graph
has two splits, that lookup and everything else.

## Where the time went, and what changed

Measured by skipping one class of operator at a time inside the real graph and reading the GPU
time per token. Before tuning, a generated token on the RX 6700 XT was 30.0 ms of GPU: 23.8 ms of
weight mat-vecs, 2.3 ms gathering and copying the recurrent state, 2.0 ms of norms and adds and
1.0 ms of Hadamard transform. On the Vega it was 32.3 ms, with the mat-vec limited by instructions
rather than by its 1 TB/s of memory, and the gated delta net kernel taking 3.9 ms per layer on a
512-token prompt against 0.7 on the RX 6700 XT.

Prompts are 87% GEMM, at 15.7 TFLOPS on the RX 6700 XT: the same efficiency ToshGEMM reaches with
Q4_0, and the PQ2_0 dequantization is 24 of the 851 instructions of its loop. What changed:

| Change | RX 6700 XT | Vega |
|---|---|---|
| Wide GEMM tile for both packings | PQ2_0 pp512 222.0 to 248.9, +12.1% | PQ2_0 pp512 162.9 to 169.4, +4.0% |
| Sign flip, head regrouping and FWHT as one kernel | PQ2_0 tg 29.24 to 30.25, +3.5% | |
| PQ2_0 mat-vec in half products (64 lanes only) | | PQ2_0 tg 28.57 to 31.17, +9.1% |
| State read from and written to the recurrent cache by the GDN kernel | PQ2_0 tg 30.48 to 32.03, +5.1% | PQ2_0 tg 32.2 to 32.8, +1.9% |
| Gate activations inside the GDN kernel on one-token batches | PQ2_0 tg 30.48 to 31.06, +1.9% | |
| GDN kernel with 16 lanes per state row | PQ2_0 pp512 251.8 to 257.8, +2.4% | PQ2_0 pp512 170.5 to 203.2, +19.2%; tg 32.9 to 34.6, +5.2% |
| Gate, up and swiglu as one mat-vec | PQ2_0 tg 32.87 to 33.01, +0.4% | PQ2_0 tg 34.78 to 36.03, +3.6% |
| rms_norm and FWHT as one kernel | PQ2_0 tg 33.03 to 33.12, +0.3% | PQ2_0 tg 35.83 to 36.42, +1.6% |
| Gated norm of the GDN block as one swiglu | PQ2_0 tg 33.12 to 33.25, +0.4% | PQ2_0 tg 36.42 to 37.0, +1.6%, measured together with the next row |
| Residual add folded into the rms_norm and FWHT kernel | PQ2_0 tg 33.25 to 33.33, +0.2% | (in the row above) |
| PTQ1_0 dequantization without divergent branches, in 16-bit integer pairs | PTQ1_0 pp512 221.9 to 236.7, +6.7% | PTQ1_0 pp512 143.9 to 184.6, +28.3% |
| PTQ1_0 mat-vec with eight rows on 64 lanes | | PTQ1_0 tg 25.43 to 27.18, +6.9% |

Each row is its own A/B pair, run on the build of that moment, so the rows do not multiply into
the totals above: each pair's baseline already includes the earlier changes, and the final runs
are a separate `-r 3` session.

Every change was measured alternating with it off, and none moved the logits: the decode path
against a float reference stays at a mean KLD below 1e-6 with the same top token everywhere.

The gated delta net changes apply to every qwen35 model. On the RX 6700 XT Qwen3.5-9B Q4_K_M goes
from 779 to 798 prompt tokens a second and from 52.8 to 55.8 generated, and Qwen3.5-4B Q4_K_M from
1338 to 1401 and from 77.5 to 83.7. Models of other architectures measure the same with and without
the patches, and give the same perplexity to the last digit. On the Vega, Qwen3.8-27B Q4_0 goes
from 160.9 to 191.4 and from 23.8 to 25.9, and Qwen3.5-4B BF16 from 610 to 753 and from 49.3 to
53.2.

## Known limitations

- The prompt speed is the ToshGEMM ceiling for these cards; making it faster means a faster GEMM
  for every quantization, not something specific to this model.
- PTQ1_0 generates more slowly than PQ2_0 on the Vega (27.3 against 36.9): its mat-vec is limited
  by instructions there, and half products, which paid off for PQ2_0, made it slower.
- Speculative decoding with the unofficial `ProCreations/Ternary-Bonsai-2-27B-DFlash2` draft
  accepts 67 to 86% of its tokens but does not speed generation up: verification batches do not
  use the one-token fusions, and verifying four tokens costs about three times one.
- Only one GPU was tested. Splitting the model across dies or cards has not been tried.
- The CPU path is correct but only as a fallback: its PQ2_0 and PTQ1_0 dot products are scalar.
