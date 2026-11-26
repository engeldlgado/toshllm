# Patches

Patches against the pinned upstream commits, one directory per engine:

```
llama/          llama.cpp, one patch per feature in a folder per area
shared-metal/   the Metal backend for whisper.cpp and stable-diffusion.cpp
whisper/        whisper.cpp, outside the Metal backend
image/          stable-diffusion.cpp, outside the Metal backend
```

`scripts/build-engines.sh` discovers them per engine and applies them in **numeric order of the
file name**, recursively, so the number is the apply order: never reuse one, and keep it when
moving a file.

## `llama/`

The port to upstream `b1b770d90d` (v1.0.0), one patch per feature, in a folder per area:

| folder | what lives there |
|---|---|
| `metal/` | the AMD Metal backend: host side, reductions and quant loads, matvec and ToshGEMM for both lane widths, AMD flash and sparse attention, fusions, older GCN and macOS 12 |
| `quant/` | turbo KV cache, Prism ternary types |
| `mgpu/` | multi-GPU: tensor groups, events and subgraphs, allreduce, TP2 fused boundary |
| `moe/` | expert prefetch, Dynamic MoE, its host cache and auto plan |
| `core/` | CPU expert dot products, loader and scheduler, 8-bit recurrent state |
| `model/` | DFlash, Flash-Next, rope and clip fixes |
| `spec/` | MTP |
| `server/` | chat templates and tool calls, MCP agent, reasoning budget, checkpoints, requests running together |

The number is global across the folders. Patches overlap in files, so they only apply in order.
**A new change gets its own numbered patch after the last one**, in the folder of its area, so it
can be read, measured and reverted on its own. When a batch of those is closed, fold each into
the feature patch it belongs to.

## `shared-metal/`

Whisper and stable-diffusion.cpp are pinned to commits from before upstream split
`ggml-metal.metal` into `kernels/`, so they cannot take `llama/0001` and `llama/0002`. The
`0001-*` series here is that same backend against the older layout, and both engines apply it
unchanged.

The image engine's ggml is older still and exactly four hunks cannot land on it. They are
applied from `patches/image/0002` in their adapted form, and `ggml-metal-impl.h` needs `-C2`
because its decode block does not match at wider context. The build script asserts which hunks
are expected to reject and stops instead of shipping a backend missing one. Do not remove that
check.

## The Polaris series (`0082`-`0092`)

This fork's AMD work for Polaris (`gfx803`, GCN 4, wave64) follows the upstream series at the
`b1b770d` pin. Every path below is reached only through `is_polaris` (`simd_width == 64` and a
gfx8xx device), so Vega, RDNA and Apple Silicon keep the code they had; only `acc_f32` widens an
existing condition rather than replacing it, and the two cases that already accumulated in float
there (a non-contiguous `src0`, `GGML_HINT_GRADIENT`) still do.

| patch | what it changes |
|---|---|
| `0082` | `MTLDevice.architecture` needs the macOS 14 SDK, not just the runtime: guarded, name fallback below 14 |
| `0083` | the Polaris host side: float accumulation OR'd in, the `mw`/`w64` tile choice, the fused norm/swiglu decode tails, the deep staging ring and the per-device pipeline cache key |
| `0084` | `kernel_mul_mm_mw`: one wave per 64x64 tile, eight rows and columns per lane, panel staged ahead of the fma loop |
| `0085` | the wave64 decode mat-vec geometry per shape and type, with the fused swiglu tail |
| `0086` | `kernel_concat_f32_t`: the conv input concat writes by tiles |
| `0087` | the prefill GEMM's K loop unrolled |
| `0088` | 16-byte activation reads in the wave64 decode mat-vec |
| `0089` | PQ2_0 prefill keeps the narrow tile on wave64 |
| `0090` | PQ2_0 prefill uses the `mw` kernel |
| `0091` | the `w64` tile keeps its place where `mw` is absent |
| `0092` | PTQ1_0 prefill uses the `mw` kernel; `mw_trit4` unpacks one byte per lane |

No instrumentation switch, no `build/` output and no app-side change is part of the series; the
macOS 12 backport of the app, the Westmere CPU dots and SenseNova Loop live on `polaris_full`.
The switches the series does carry are kill switches for its own paths (`TOSH_MM_MW_DISABLE`,
`TOSH_MM_W64_ENABLE`, `TOSH_MV_Q4K_R8`, `TOSH_MV_Q6K_R4`); every one of them defaults to the
behaviour the measurements picked.

## Changing one

The vendor tree carries every patch at once, so `git diff` there is all of them, and it may also
carry experiments that are in no patch. Work in a worktree that has only the series:

```sh
git -C vendor/llama.cpp worktree add -f /tmp/series --detach <LLAMA_COMMIT>
# apply the patches before the one to change, commit, apply that one, edit, then
git -C /tmp/series diff -U8 <base-commit> > patches/llama/<area>/<NNNN-name>.patch
```

Three rules that have each cost real time:

- **`-U8` for `llama/`.** Anything narrower rewrites every hunk header in the file, and the
  `git diff` default of three lets a hunk land in a different kernel while the build still
  exits 0. Add new files with `git add -A` and take `git diff --cached`, or they are left out.
- **Every later patch must still apply.** `scripts/check-patch-series.sh <LLAMA_COMMIT>` runs the
  whole series in a throwaway worktree and reports each patch.
- **Verify the round trip.** Apply the whole series into a worktree at the pinned commit, and
  diff it against the tree you built and measured. No source file may differ.

`scripts/build-engines.sh` resets the vendor tree and re-applies the patch files, so working
tree edits are discarded: regenerate before building, never after.
