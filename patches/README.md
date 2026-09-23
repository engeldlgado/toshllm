# Patches

Patches against the pinned upstream commits, one directory per engine:

```
llama/          llama.cpp, seven patches that rebuild the ported tree
shared-metal/   the Metal backend for whisper.cpp and stable-diffusion.cpp
whisper/        whisper.cpp, outside the Metal backend
image/          stable-diffusion.cpp, outside the Metal backend
```

`scripts/build-engines.sh` discovers them per engine and applies them in **numeric order of the
file name**, recursively, so the number is the apply order: never reuse one, and keep it when
moving a file.

## `llama/`

`0001` to `0007` are the port to upstream `9575389609d6`, split by the files they touch. They are a
baseline, not somewhere to add things: **a new change gets its own numbered patch after them**,
one patch per change, so each one can be read, measured and reverted on its own.

| | area |
|---|---|
| `0001-metal-kernels` | `ggml/src/ggml-metal/kernels/` |
| `0002-metal-backend-host` | the rest of `ggml/src/ggml-metal/` |
| `0003-moe-cache` | `tosh-moe/`, turbo quant |
| `0004-ggml-core` | `ggml/` outside the Metal backend |
| `0005-llama-core` | `src/` |
| `0006-common-and-spec` | `common/` |
| `0007-tools-and-build` | `tools/`, `tests/`, top level CMake |

Only touch one of the seven when the change belongs to the port itself. Together with everything
numbered after them they reconstruct the built tree byte for byte, which is what the round-trip
check below verifies.

The seven replaced the old per-area folders (`llama/metal/`, `llama/core/`, `llama/model/`,
`llama/server/`) at the port; the running numbering they used did not go away.

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

## Regenerating one

The vendor tree carries every patch at once, so `git diff` there is all of them. Because the
`llama/` sets are disjoint by file, one patch is its own files diffed out of the live tree:

```sh
f=patches/llama/0002-metal-backend-host.patch
files=(${(f)"$(grep '^diff --git' $f | sed 's|.* b/||')"})
git -C vendor/llama.cpp diff -U8 -- $files > $f
```

Three rules that have each cost real time:

- **`-U8` for `llama/`.** Verified: at that width `0002`, `0004`, `0005` and `0006` regenerate
  byte for byte, and anything narrower rewrites every hunk header in the file. `0001`, `0003`
  and `0007` also add files, which `git diff` will not carry on its own. Never the `git diff`
  default of three: with it a hunk lands in a different kernel and the build still exits 0.
- **Check the tree is the one you think it is** before regenerating. If the files modified in
  the vendor tree do not match the files the series touches, stop: an experiment was left
  applied, or a patch was left reverted, and regenerating will overwrite it.
  ```sh
  diff <(cat patches/llama/000*.patch | grep '^diff --git' | sed 's|.* b/||' | sort -u) \
       <(git -C vendor/llama.cpp status --short | awk '{print $2}' | sort -u)
  ```
- **Verify the round trip.** Add a worktree at the pinned commit, apply the whole series into
  it, and diff it against the live tree. No source file may differ.

`scripts/build-engines.sh` resets the vendor tree and re-applies the patch files, so working
tree edits are discarded: regenerate before building, never after.
