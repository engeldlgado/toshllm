# 0058 scope: TP decode — the levers that survived 0057

Follow-up to `0057-peer-resident-exchange-scope.md`. That document killed the fabric dream:
at decode sizes the bridge offers exactly one cheap cross-device primitive (`MTLSharedEvent`
signal/wait, ~0), while remote **reads** cost ≈475 µs/16 KiB in situ and remote **writes**
hard-assert in the AMD driver. Any remaining TP-decode work must live inside the host-staging
design or inside the meta layer.

Rig and model as in 0056/0057 (Mac Pro 2019, 4× W6800X Duo dies, GLM-4-9B-0414-Q4_K_M,
`llama-bench -p 0 -n 128 -r 3 -sm tensor`). Shipped after 0057: **tg128 30.04**.

## The ledger (per allreduce site, ~80 sites/decode-token)

| component | cost | status |
|---|---|---|
| outbound D2H blit (16 KiB → WC host block) | ≈ 57 µs | fixed-cost per blit, not bandwidth |
| inbound H2D blit (partner's slot → `tmp`) | ≈ 57 µs | same |
| add kernel + inbound blit-in + encoder split | ≈ 60 µs | local work |
| the two `encodeWaitForEvent` waits | ≈ 80 µs | cross-device event wakeup latency |
| commit + signals | ≈ 0 | free — nothing to win by merging command buffers |

Two ceilings frame everything:

- **`noop` mode = 59.5 t/s** — with every exchange removed, TP4 still only reaches solo speed
  (solo measured 65 the same day). The meta layer's per-subgraph dispatch/encode floor eats the
  4× compute scaling. *No exchange-path patch can cross ~60 t/s.*
- A tensor split that perfect reads as **~60 t/s ≤ solo (65–91)**. TP decode improvements only
  matter for models that cannot be served solo or layer-split — on this box, dense > ~28 GB.
  Everything else is served faster by N solo replicas (see `tp-batch-2026-09-12`).

## Candidates, ranked

### A. Epilogue-direct staging (attacks the 57 µs outbound blit) — do first

The boundary node's compute already writes `t_self` in VRAM; the exchange then runs a *separate
blit* of 16 KiB into `link->wrap_src` (WC). The blit's 57 µs is encoder/scheduling fixed cost,
not transfer. If the boundary kernel instead stored the result through `wrap_src` (a WC store is
fire-and-forget and hides under the kernel's tail), the outbound blit disappears from the critical
chain: sites drop ~255 → ~200 µs → **est. 30 → 34–38 t/s**.

Boundary nodes are only two kinds: the row-parallel output matmul (`o_proj`/`down_proj`) and, at
sites where the device's slice was zero, the 0056 broadcast (already handled separately).

**Probe before committing** (reuse the `TOSH_MGPU_XDEV_MEASURE` harness from 0057): add mode
`kstore` = a trivial compute kernel writing 16 KiB into `wrap_src` instead of the blit, same
event bookkeeping. If `kstore` blit-substitution measures < 20 µs, implement; if not, close A.

Implementation risk: plumbing a staging destination into the mul_mat epilogue means a new aux
buffer binding on the boundary kernels and a per-tensor flag ("also store to staging") set by
`ggml_backend_metal_comm_allreduce_tensor` before the next encode. Contained to
`ggml-metal.cpp` (comm hook) + the two epilogue kernels. Medium effort.

### B. One per-link seq allocator, then A/B star vs butterfly topology — enablement, then probe

0057 recorded the landmine: `exchange_reduce` and `cpy_xdev_events` advance `link->seq` from
different generators (`seq_round` static vs `++link->seq`) and only `>=`-style waits save it.
**Any further exchange work must land this fix first** — it is cheap and removes a latent
deadlock, independent of everything else.

With that done, probe star-vs-butterfly for n=4 sites: today's butterfly is 2 rounds of
push+wait+add per device (4 host blits + 1 add per site per device). A star (3 contributors push
into 3 slots of one arena; R0 pulls+adds+publishes one result; contributors pull it) has the same
two-hop serial depth but shallower per-device work only if R0's add reads the three host slots
*in-kernel* (no blit-in). Whether PCIe reads inside a kernel beat blit+VRAM-add is unmeasured —
probe mode `staradd` answers it in one sitting. Expect ≤ +10 % even if positive; **deprioritize
behind A**.

### C. Batch-encode adjacent subgraphs (attacks the 60 t/s dispatch floor) — the big one

The only lever that can cross the noop ceiling: the meta layer submits one graph submission per
device per subgraph between reductions; `noop` shows that dispatch alone costs the 4× scaling.
The fix is to encode *several layers' worth of device-local work* into each command buffer,
interleaving the subgraph boundaries — a scheduler restructure in the meta backend
(`ggml-meta`, not Metal), large effort, regression risk on every other multi-GPU path. Only
worth opening once a real workload on this box needs TP decode (i.e. a dense model that fits in
128 GB but not in ~28 GB — the 30–64 GB band, where a layer split also works and decodes at
80 t/s; TP only wins prefill there).

### D. Non-code answers already measured

- **Batching** amortizes every line in the ledger: TP4 @ 32 streams = 106 t/s aggregate
  (`tp-batch-2026-09-12`). If the goal is multi-user throughput, solo replicas beat this too.
- **TensorMesh rows of two** decode at 57–58 t/s — the best TP-flavoured decode on this machine,
  because a row pays one partner's wait instead of three. For a > 28 GB dense model, mesh/layer
  is the decode answer today; TP is the prefill answer.

## Decision

1. Land the per-link seq unification (B's first half) as its own small patch.
2. Add probe modes `kstore` + `staradd` to the 0057 harness; run `llama-bench -p 0 -n 128 -r 3
   -sm tensor` with the 0057 protocol (±15 only counts as signal).
3. Implement A iff `kstore` shows the kernel store ≳ 37 µs cheaper than the blit. Expected result
   target: tg128 ≥ 35.
4. Treat C as a separate project, only after a model on the bench demands it.
