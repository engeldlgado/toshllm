# reference/

Source kept for future work. **Nothing here is applied by the build** —
`scripts/build-engines.sh` names the patches it applies one by one, and none of
them live in this directory.

## `turboquant-kv-upstream.patch`

The TurboQuant KV cache implementation (llama.cpp PR 23962), extracted from the
fork before the engine was retired in 0.82.0. It adds the `turbo2/3/4` KV cache
types: Walsh-Hadamard transform + PolarQuant at 2/3/4 bits, which cut the KV
cache to roughly a sixth of `f16`.

- Applies to llama.cpp commit **4f13cb7** (verified with `git apply --check`).
  Later commits will conflict; it is a reference, not a rebasable patch.
- Taken from `2cbfdc62` (`feature/turboquant-kv-cache`), README and docs excluded.
- Notable pieces: `ggml/src/ggml-turbo-quant.c` (the quantizer),
  `src/turbo-rotation-data.h` (the rotation matrices), types 42/43/44 in `ggml.h`.

Kept because the branch lives in a pull request ref, which can disappear. The
plan for reimplementing it on the official engine, including the part the PR
never wrote (the `f32 -> turbo` requantize kernels, whose absence crashes any KV
shift), is in the project notes.

## `0002-turboquant-pr-fixes.patch`

Our AMD fixes, applied to the TurboQuant fork rather than the official engine.
Mostly a duplicate of `patches/0001`, kept only so the fork can be rebuilt as it
shipped. Nothing to port from here.
