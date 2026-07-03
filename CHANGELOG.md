# Changelog

All notable changes to ToshLLM are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/).

## [0.81.44] - 2026-07-03

### Improved
- **Faster prompt processing**... the AMD tiled matmul now does its math in packed half precision, which AMD cards run at twice the speed. Prompt processing jumps about 50% on both engines (Qwen3-8B: ~310 to ~470 t/s) with output quality verified identical. Generation speed is unaffected (that one is memory-bound).
- **Much faster prompts in long conversations**... a new attention kernel processes prompt tokens in groups of 16 that share the stored conversation instead of each token re-reading all of it. Prompt processing at 4K of context goes about 3x faster (103 to 289 t/s on an 8B), and the deeper the chat, the bigger the win... long conversations stop feeling slower to respond over time.

### Added
- **Image generation studio**... a new experimental Images tab in the main window generates images locally on the GPU with stable-diffusion.cpp, which shares the same Metal stack as the language engines. Supports text-to-image and image-to-image (pick a starting image and set how strongly it steers the result), and runs on the AMD GPU with the same tiled matmul the language engines use.
- **Image model catalog**... a set of models spanning GPU sizes, each with its own VRAM budget so the app only offers the ones that fit, from small models on 4 GB cards up to larger ones on 24 GB+ cards. Resolution options scale to the selected model and the detected VRAM.
- **Custom image models**... point the studio at your own checkpoint, VAE and text-encoder files to run models beyond the built-in catalog.
- **Pick how many GPUs to use**... on a multi-GPU machine a setting chooses how many GPUs to split a model across instead of always using every detected GPU.
- **Image engine logs**... the Logs tab now switches between the server log and the image generation log.

### Changed
- **Newer bundled engine**... updated the bundled llama.cpp to a recent master build.

## [0.81.42] - 2026-06-27

### Changed
- **AMD Flash Attention defaults to GPU**... the AMD kernel is now on by default for bundled engines and is restored when switching back to bundled or TurboQuant, so supported AMD runs prefer the custom GPU path instead of the standard CPU Flash Attention path.
- **Clear Flash Attention labels**... settings and benchmarks now distinguish the standard `Flash Attention (CPU)` path from the `AMD Flash Attention (GPU)` kernel without burying the distinction in tooltips.

### Fixed
- **Quantized KV benchmarks**... any quantized KV cache now forces `-fa 1` for server and benchmark runs, as llama.cpp requires, while leaving `TOSH_FA_AMD` under the AMD kernel toggle. Turning the AMD kernel off still allows the standard CPU Flash Attention fallback for compatibility and comparison.
- **Benchmark history**... each benchmark now records and displays whether it used `FA CPU`, `FA AMD GPU`, `FA auto` or no Flash Attention, and the full text log includes the effective FA route for shareable results.

## [0.81.41] - 2026-06-27

### Fixed
- **AMD Flash Attention toggle**... the app no longer turns on Flash Attention implicitly when switching engines or using quantized KV values. Standard Flash Attention and the AMD GPU kernel now follow their own controls: `-fa` stays off when Flash Attention is off, and `TOSH_FA_AMD` is only set when the AMD kernel toggle is enabled.

## [0.81.40] - 2026-06-27

### Added
- **AMD Flash Attention on the bundled engine**... the custom AMD attention kernel, until now only on the experimental engine, runs on the default bundled engine too, keeping attention on the AMD GPU instead of the CPU. A toggle sits right next to the standard Flash Attention setting, with a clear distinction: standard Flash Attention runs on the CPU on AMD GPUs, the AMD kernel runs on the GPU. On an 8B this lifts generation from ~12 to ~58 t/s. Covers standard KV (f16/q8_0/q4_0) and head dims 128/256/512.

### Fixed
- **Vision detection**... a text model no longer shows as vision-capable just because an unrelated projector with a matching size happens to sit in the same models folder. A projector is paired only when its name matches the model (the `<model>.mmproj.gguf` or `mmproj-<model>.gguf` convention), so models like Qwen3-8B stop borrowing another model's `mmproj`.

### Changed
- **Vision-capable models**... confirmed image input working with the AMD Flash Attention kernel across the Qwen3-VL family (Qwen3-VL-2B, Qwen3.5-9B, Qwen3.6-14B/35B) and Gemma 3, with Gemma 4 on the bundled engine. The Qwen3-VL-2B recommendation now notes it can be unpredictable on long replies.

## [0.81.39] - 2026-06-24

### Fixed
- **Image input on the experimental engine**... picking the experimental engine now turns on the AMD Flash Attention kernel by default, which fixes garbage output (`0000…`) on large MoE / K-quant vision models. Gemma 4 vision still needs the bundled engine.
- **Update cleanup**... the downloaded `.dmg` is removed after a successful install instead of piling up in Downloads; it's kept if the update fails.
- **Recommended models**... replaced the Moondream2 vision pick (its chat template can't carry an image through llama-server, so every image returned HTTP 400) with Qwen3-VL-2B, a tiny vision model that works on both engines.

## [0.81.38] - 2026-06-23

### Improved
- **Disable thinking actually sticks**... turning reasoning off (or typing `/no_think`) now forces the model to stop thinking even on templates that ignore the flag, instead of spending the whole budget reasoning.
- **Multi-GPU recommendations**... model suggestions count combined VRAM when the split is on, so large models show as full-GPU instead of suggesting CPU offload.

## [0.81.37] - 2026-06-23

### Added
- **Per-GPU VRAM on the Dashboard**... a new GPUs card shows a usage bar for each detected
  GPU, so multi-GPU machines see what each card is holding instead of a single guessed total.
- **VRAM in the menu bar**... a new setting shows VRAM usage next to the menu bar icon
  (aggregate percentage) or as per-GPU bars inside the panel.
- **Consolidated menu bar panel**... it now lists every server, the main one first, each with
  its own start/stop, a chat link while running, and its own "discoverable on network" toggle.

### Changed
- **Networking toggle applies live**... turning "discoverable on local network" on or off now
  restarts the running server automatically to apply it, instead of staying disabled until you
  restart by hand.
- **Add-server button**... it now gives press feedback and scrolls to the new card, so a click
  always produces something visible.

### Fixed
- **Per-GPU VRAM reading**... the monitor read only the first accelerator, so a second GPU's
  usage was missing; each GPU is now paired to its accelerator by registry ID.
- **Independent KV slot caches**... each server's on-disk KV slots now live in a per-port
  folder, so servers with cache persistence no longer overwrite each other's slot files.

## [0.81.36] - 2026-06-22

### Added
- **Multiple servers at once**... run several independent engine instances from the
  Dashboard, each with its own model, GPU, port, profile and vision/network toggles. Add
  one with the floating button, remove it with the x. Handy for serving different models
  side by side or pinning one model per GPU. The chat keeps using the main server.
- **Per-server logs**... the Logs tab gets a picker to switch between each running server's
  live log.
- **Model picker on the main server card**, alongside the one the added servers already had.

### Fixed
- **Cleaner shutdown of multiple engines**... the engine tracker now records every running
  instance, so each one is reaped on quit instead of only the last.

## [0.81.35] - 2026-06-22

### Added
- **Text-only toggle for vision models** — vision-capable models now show an eye control on
  the Dashboard. Turn it off to run the model as text-only and free the VRAM its image
  encoder would otherwise use.

### Fixed
- **Multi-GPU split activation hand-off** — the cross-device copy in a layer split used
  an invalid Metal blit (a blit can't reach another device's buffer); it now stages
  through host memory. This targets the corrupted generation reported on dual-GPU setups.
  Applies to both engines. (Advanced: `GGML_METAL_CROSS_STAGING_DISABLE=1` uses the
  generic fallback copy.)

## [0.81.34] - 2026-06-22

### Improved
- **Reproducible benchmarks** — each run records the GPU it used and a full
  configuration snapshot, and any run (not just the last) can be saved as a profile.
- **Benchmark profile picker** — seed a benchmark from a saved profile, apply a result
  to the global default, or save it as a new profile; the history highlights your best
  run and lets you save, apply or delete any row.
- **Profiles on the Dashboard** — the server card shows the active profile in a picker at
  its top-right, with a "Default (no profile)" entry that restores the configuration you
  had before applying any profile.
- **Benchmark history on disk** — runs are written to a shared `benchmarks.txt` with a
  full header (model, GPU, engine, args) for sharing or debugging, kept for 3 days.

### Fixed
- **"Logs in Finder" opens the logs folder** instead of a generic user folder.
- **Crash-safe logs** — log and benchmark writes are flushed to disk immediately, so a
  machine freeze no longer loses the recent history.
- **Models list populates at launch** — no need to re-select the models folder to see them.
- **"Reset to defaults" reverts the engine** from Turbo back to Bundled.

## [0.81.33] - 2026-06-21

### Improved
- **ToshGEMM now accelerates MoE prefill** — the per-expert matmul uses the tiled
  kernel too, so Mixture-of-Experts models speed up on their GPU-resident experts,
  not just dense layers (about +22% on top of the dense gain when experts sit in VRAM).
- **Benchmark: MoE expert-offload control** — adjust "MoE experts on CPU" directly in
  the Benchmark for MoE models, alongside Find-optimum.

### Fixed
- **An incompatible projector no longer blocks a model** — if a paired mmproj fails to
  load, the model now starts text-only instead of refusing to launch, and that pairing
  is remembered so it isn't retried (a different projector for the model still works).
- **MoE expert control hidden on dense models** — the "MoE experts on CPU" setting is
  disabled for non-MoE models, where the engine ignores it anyway.

### Changed
- **TurboQuant weight models (tq3_1s/tq4_1s) are blocked for now** — they decode to
  incorrect output on this engine, so the app refuses to load them with a clear message
  instead of producing garbage. Standard quants are unaffected.

## [0.81.32] - 2026-06-21

### Improved
- **Faster prompt processing on AMD (ToshGEMM)** — a new tiled matmul kernel replaces
  the slow fallback path, ~2.4–3× faster prefill / time-to-first-token on AMD GPUs.
  Output and generation speed are unchanged; auto-enabled on AMD RDNA.

### Fixed
- **Multimodal projector (mmproj) pairing** — each model now pairs only with a
  compatible projector, so vision models no longer fail to load by grabbing the wrong one.
- Minor fixes to profile saving.

## [0.81.31] - 2026-06-20

### Improved
- **Chat UI improvements and better chat performance**: smoother streaming, a
  rewritten transcript scroll with reliable auto-follow and scroll-to-bottom, a
  live prefill status, and assorted polish.

### Added
- Optional **smooth typing** animation (Settings).

### Fixed
- Chat no longer blanks out when switching or reopening conversations.
- A reply being generated no longer appears in other conversations.
- Concurrent requests share one KV pool, so extra slots don't shrink the chat's
  context window.

## [0.81.30] - 2026-06-20

### Added
- **GCN/Vega (wave64) safe mode**, opt-in on the official engine: type
  `GGML_METAL_WAVE64_SAFEMODE=1` in Extra arguments (any `KEY=VALUE` there is now passed
  as an engine env var). Validated coherent on an RX 580; off by default, no-op on
  Apple/RDNA. Extra arguments now route uppercase `KEY=VALUE` tokens to the environment.
- **Per-session server logs** with date-and-time filenames (survive a crash) that
  auto-delete after 3 days, plus a self-contained log header (version, engine, model,
  GPUs, args/env). Start/stop the server and pick a model from the Logs tab.
- **System info on the dashboard**: Mac model and macOS version.
- **Reset options to defaults** button (keeps models and the models folder).

### Fixed
- **eGPU full speed**: forces VRAM-resident buffers on external GPUs (was streaming over
  Thunderbolt at ~0.8 t/s), automatically when an eGPU is selected, with a manual toggle.
- CPU-threads selector capped to the machine's actual thread count.
- Port no longer shows a thousands separator (8080, not 8.080).

### Changed
- UI polish: dashboard cards aligned to equal height, server quick-settings (port,
  discoverability) without layout jumps, cleaner model estimate rows.

## [0.81.29] - 2026-06-19

### Fixed
- **External GPUs (eGPU) run at full speed.** The Metal backend forces shared
  (system-memory) buffers for external GPUs, so weights stream over Thunderbolt every
  op (~0.8 t/s). ToshLLM now forces private, VRAM-resident buffers
  (`GGML_METAL_SHARED_BUFFERS_DISABLE`) automatically when an external GPU is selected,
  with a manual "VRAM-resident weights" toggle (shown only when an eGPU is present) for
  the default case where macOS picks the eGPU. Likely also clears the
  `failed to decode prompt batch (res = -3)` benchmark error on eGPUs.

### Added
- **Self-contained server log header.** Each server start now logs the app version,
  engine, model, detected GPUs (flagging external/eGPU), the GPU selection, the resolved
  settings and the exact args/env (API key redacted) — so a single pasted log is enough
  to debug a remote setup.

## [0.81.28] - 2026-06-19

### Added
- **Real GPU selection and multi-GPU split on Metal.** The bundled Metal backend always
  used the macOS system-default GPU and ignored the picker; both engines are now patched
  so the GPU picker pins the engine to the exact physical card and "Split across all GPUs"
  registers every physical GPU so a model's layers can actually span separate cards. The
  default path (no selection, no split) is unchanged. Cross-GPU split on AMD/Metal is still
  experimental and unvalidated — keep an eye on coherence and stability.
- **Verified vision catalog picks** from the ggml-org multimodal collection: Moondream2
  (tiny/fast) and Pixtral-12B (strong OCR), alongside a small Gemma-3-4B vision pair.

### Fixed
- **Failed downloads can be retried.** A retry button now appears inline on a failed
  download (catalog and search results), instead of leaving the card stuck on "Error" with
  no way back to the download action.
- **Multimodal projector (mmproj) detection is reliable.** Projectors are saved under a
  model-specific name (`<model>.mmproj.gguf`) instead of the generic, collision-prone repo
  name (e.g. `mmproj-F16.gguf`), so pairing is unambiguous even with several models in one
  folder, and deleting a vision model removes its projector too. The auto-fetch now prefers
  q8/f16 projectors over bf16/f32 on AMD/Metal.

### Changed
- **Unverified vision is clearly flagged.** Vision models outside the curated catalog show
  a visible "Unverified" badge and an inline warning (no hover required) that the
  auto-selected projector's compatibility isn't guaranteed.

## [0.81.27] - 2026-06-19

### Added
- **Optional local-network API discovery.** A new toggle in Settings and the menu-bar
  panel binds the server to the LAN and advertises `ToshLLM API` through Bonjour. It is
  off by default, requires a server restart, and warns when API-key protection is off.
- **LAN and multimodal API guidance** in the built-in bilingual documentation, including
  local-network URLs, `/v1/models`, OpenAI `image_url` input and vision-cache limitations.

### Fixed
- **Multi-GPU benchmarks now use every selected GPU on both engines.** Benchmark runs
  inherit the server's GPU, KV-cache, Flash Attention and MoE options, including
  `--split-mode layer`, instead of silently using an independently-built argument list.
- **Vision models no longer trigger unsupported slot operations.** ToshLLM skips disk
  slot persistence, prewarming and cache-reuse when an `mmproj` is loaded, preventing
  `This feature is not supported by multimodal` errors from `llama.cpp`.

## [0.81.26] - 2026-06-18

### Added
- **Vision / Coder / MoE badges and filters in the catalog.** Models are tagged and
  the Models tab can filter by All / Vision / Coder / MoE. Hugging Face search results
  show a "Vision" badge when expanded (if the repo ships a multimodal projector).
- **Automatic vision-projector download.** Downloading a vision model also fetches its
  `mmproj` automatically. If a vision model is already downloaded but its projector is
  missing, a "Download vision file" button on its card gets it.
- **Retry button** for failed model downloads.

### Changed
- **Chat parameter tooltips match Settings** — Reasoning, Creativity, Response tokens
  and the system prompt now use the same pinnable ⓘ info popovers as Settings.

## [0.81.25] - 2026-06-18

### Added
- **Attach PDFs, scanned PDFs and more file types in chat.** PDF text is extracted
  automatically; scanned PDFs (no text layer) are read on-device with OCR. Text files
  in more encodings are accepted, and other binaries contribute their readable strings.
- **Image input for vision models (experimental).** If the loaded model has a paired
  multimodal projector (an `mmproj-*.gguf` next to it), you can attach images and ask
  about them; the projector is detected and loaded automatically on both engines. The
  vision encoder runs partly on the CPU on AMD GPUs (some Metal ops unsupported), so it
  works but isn't fully GPU-accelerated.
- **Configurable models folder.** Choose where models are downloaded and scanned
  (Settings → Application), instead of the fixed `~/models`.

### Changed
- **Higher chat response cap.** The response-token options now go up to the full
  configured context (e.g. 16k at the default, 32k+ when you raise the context).
- **Clearer "context full" handling.** Large attachments now warn before sending (with
  an estimate vs the context size), and the message explains it counts files + history.

### Fixed
- Multi-file attachment errors are now reported per file instead of a single generic line.

## [0.81.24] - 2026-06-17

### Fixed
- **Crash with prompt cache reuse + quantized KV.** A KV-cache shift on a standard
  quantized cache (q8_0/q4_0) dereferenced a null tensor in the rope-shift path and
  crashed the engine. Fixed in both engines (patches 0001 and 0002).

### Added
- **Prompt cache reuse** toggle (Settings) — reuses the cache across mid-prompt edits
  (coding assistants) and trimmed reasoning instead of reprocessing. Fast but
  approximate; turn it off for exact, reproducible results.
- **Styled, pinnable tooltips** — the ⓘ next to each setting opens a formatted
  explanation on a short hover, and a click keeps it open.

### Changed
- **Settings are now self-consistent** — incompatible options disable or hide each
  other (turbo KV types hide while cache reuse is on; Flash Attention follows the AMD
  kernel; disk cache requires the AMD kernel).
- **AMD Flash Attention kernel now covers all standard KV combinations** (experimental
  engine): f16/q8_0/q4_0 in any keys/values mix run on the GPU — so you can compress the
  keys while keeping values at full precision (q8_0/f16) without falling back to the CPU.
  Tooltips and docs updated; kernel head-dim coverage noted as 128/256/512 (Gemma 4).

## [0.81.23] - 2026-06-17

### Added
- **Remember conversations (disk cache)** — optional, on the experimental engine
  (Settings). Persists each chat's KV cache, so reopening it or restarting the app
  skips re-processing the prompt. Reload is byte-exact and verified faithful (same
  output, even with sampling); on a long chat it reloads in well under a second
  instead of re-prefilling.
- **Faster cold start for external clients** (VS Code / Cline): the engine now
  pre-warms its cache across restarts, so the first request skips the multi-minute
  prefill of the big fixed prompt (experimental engine, non-MTP models).
- **Split model across all GPUs** (experimental) — splits the model's layers over
  every detected GPU instead of one, for machines with multiple cards. Shows a
  visible warning: it's unvalidated on AMD/Metal and needs testing.

### Changed
- Unit tests now run locally via `./scripts/test.sh` (points at Xcode for XCTest).

## [0.81.22] - 2026-06-17

### Changed
- **Default language is now English.** A fresh install starts in English; your
  choice in Settings is remembered and always wins.

## [0.81.21] - 2026-06-16

### Fixed
- **Gemma 4 no longer runs its attention on the CPU.** Its global-attention
  layers use head dim 512, which the AMD Flash-Attention kernel didn't cover, so
  they fell back to the CPU during prompt processing. The kernel now handles head
  dim 512 (NSG=8) and auto-enables for these models on the experimental engine.
  - With quantized KV (q8_0) the global layers go ~8 → ~36 tokens/s (≈4× over the
    CPU fallback); output verified coherent.
  - No regression on existing models (4B/8B head 128, 9B coder head 256 unchanged).

## [0.81.20] - 2026-06-16

### Added
- **Context up to 256k tokens** in Settings (for testing), with a warning when
  it's very large; chat response-token options raised to match.

### Changed
- **Download progress is visible on the card** — a live bar with %, MB and
  pause/cancel, right where you press Download.

### Fixed
- **"Reasoning off" now also sends `/no_think`**, so more models actually stop
  thinking (some reasoning-only models still can't be turned off).
- Build error in the test suite (it used the renamed recommendation API).

## [0.81.19] - 2026-06-16

### Added
- **Logs tab** — full-height server log with search, severity filter
  (all/warnings/errors), follow toggle, copy and diagnostics export.
- **More recommended models** — picks per use case: fastest, everyday (8–9B),
  top quality and coding.
- **Live "Trending on Hugging Face"** list in the Models tab.

### Changed
- **Models tab redesigned** — cards instead of a dense list, split into
  Recommended / Browse / My models.
- **Recommendations are hardware-aware** — chosen from the AMD VRAM tiers real
  Intel Macs and Hackintoshes use.
- **Catalog refreshed** — added Llama-3.1-8B, GLM-4-9B and Gemma-4 (12B and the
  26B-A4B MoE).

### Fixed
- **Long answers no longer slow down or stall generation.** The chat reader was
  decoupled from rendering, so a slow frame can't backpressure the engine; the
  streamed text is now drawn incrementally instead of fully re-parsed each token.

## [0.81.18] - 2026-06-16

### Fixed
- **Chat could drop the connection ("cancelled after ~30s") while waiting for
  the first token on a long prompt.** The streaming request ran on
  `URLSession.shared`, whose ~60-second idle timeout effectively overrode the
  per-request value, so the connection was cut when the first token took longer
  than that (e.g. a long prompt re-processing). Streaming now uses a dedicated
  session with a 10-minute idle timeout, so a slow first token no longer drops
  the chat. Confirmed the server was never the cause — it held a 168-second
  request to completion in testing.

## [0.81.17] - 2026-06-16

### Fixed
- **The experimental engine took ~45 s to load a model and often "started only
  after several tries."** The bundled engines compiled their Metal shaders from
  source on every launch; with the larger AMD Flash Attention kernel set that
  runtime compile ballooned to tens of seconds, so the app looked stuck and
  needed retries. The engines now ship a precompiled Metal library and load it
  directly — model load drops to ~2 s. The shader source stays embedded as a
  fallback: GPUs whose feature set doesn't match the precompiled library (M5-class
  tensor GPUs, or any case where it can't load — e.g. an older macOS) transparently
  compile from source, so nothing breaks and there's nothing extra to install.

## [0.81.16] - 2026-06-16

### Changed
- **AMD Flash Attention kernel is much faster at depth.** Each threadgroup now
  splits the KV stream across more simdgroups (32 for head dim 128, 16 for head
  dim 256), turning the long serial decode loop into shorter parallel ones. On
  the reference RX 6700 XT with a turbo KV cache: generation at 4096 tokens of
  context goes from 19 → 33 t/s on an 8B (+75%) and 26 → 31 t/s on a 9B coder
  model (+17%); at 2048 tokens, +42% and +11%. Output is bit-for-bit unchanged
  (validated on both head dims); prompt processing is within ~3%. The kernel also
  skips fully-masked positions before the score computation, trimming wasted work
  in long-prompt prefill.

### Fixed
- **Chat generation no longer stalls on long conversations.** While streaming, the
  whole Markdown transcript was re-laid-out on every token; on a discrete AMD GPU
  (shared between the UI and Metal inference) those layout passes starved the
  inference and froze generation for several seconds at a time. Completed Markdown
  blocks are now frozen (only the block being written re-renders), and the
  auto-follow scroll is throttled so it no longer measures the entire transcript on
  every token. Generation stays smooth on long chats.

## [0.81.15] - 2026-06-15

### Added
- **AMD Flash Attention kernel now runs prompt processing on the GPU too**, not
  just generation. For quantized/turbo KV (which forces Flash Attention) the CPU
  fallback collapses with depth — e.g. turbo prefill at 2k tokens ~6 t/s — while
  the GPU kernel stays flat at ~100 t/s (q8 2.5×, turbo 16× faster at 2k).
  Validated with needle-in-haystack retrieval over long contexts. This removes
  the multi-minute prompt-processing stalls on long conversations.

### Fixed
- **Crash with the AMD kernel + quantized KV cache.** `--cache-reuse` shifts KV
  chunks when a prompt diverges mid-way (e.g. on auto-compact); the kernel reads
  the quantized cache directly and did not account for that shift, segfaulting on
  the next attention op. Cache reuse is now disabled while the AMD kernel is active.
- **Chat could time out on long prompts.** The streaming idle timeout was raised
  to 3 minutes as a safety net (largely moot now that prompt processing runs on GPU).
- **Slow/laggy chat rendering on long answers.** The Markdown re-render now flushes
  adaptively (less often as the answer grows) so it keeps pace with generation.

## [0.81.14] - 2026-06-15

### Added
- **AMD Flash Attention decode kernel** (experimental). A from-scratch Metal kernel
  that runs generation-time attention on discrete AMD GPUs, exposed as a toggle on
  the experimental engine (Settings → Inference engine → Experimental → "AMD Flash
  Attention kernel"). Supports head dims 128 and 256 and KV types f16, q8_0, q4_0
  and turbo2/3/4 (including the asymmetric pairs the TurboQuant engine allows).
  Quantized and `turbo*` KV caches require Flash Attention, which otherwise falls
  back to the CPU on AMD; the kernel keeps it on the GPU (measured ~14 → ~31 t/s
  for turbo KV at 1k context). Prompt processing still runs on the CPU. Off by
  default; the standard engine is unchanged. See the README research note.

### Fixed
- **MTP crash on AMD.** Speculative decoding (`draft-mtp`) could abort mid-generation
  with `GGML_ASSERT(buf_dst)` in the Metal backend: the draft path reads hidden-state
  embeddings back from the GPU through an asynchronous transfer that the AMD staging
  patch did not yet cover. The staging fallback now also wraps that async read path.

## [0.81.1] - 2026-06-12 (pre-release)

First public pre-release. Core functionality is complete and validated on the
reference hardware (Intel Mac + RX 6700 XT 12 GB); broader testing is ongoing
before 1.0.

### Highlights
- Native SwiftUI app for running LLMs locally on Intel Macs with AMD GPUs (Metal).
- Bundled, AMD-patched llama.cpp engines (static, self-contained) — fixes
  corrupted output and PCIe-bound performance on AMD dGPUs (~8× faster than stock).
- Native chat: persistent multi-conversations, full Markdown with code copy,
  regenerate, system prompt, per-message tokens/sec.
- Model manager: curated catalog with per-model VRAM/RAM estimates for the
  detected hardware, Hugging Face search, downloads, one-click delete.
- MoE-aware: automatic `--n-cpu-moe` calculation for 35B-class models on 12 GB GPUs.
- MTP speculative decoding support (+34% generation, lossless).
- Dual engines: official + experimental TurboQuant (KV cache to ~16%,
  100k+ token contexts).
- Benchmarks with history, configuration chips and comparison charts.
- KV cache quantization, `--mlock`, Flash Attention and per-GPU selection.
- Profiles (full config snapshots, engine included), menu bar mode, auto-start.
- Bilingual UI (English/Spanish) with tooltips on every setting and built-in docs.
- OpenAI-compatible API + minimal web chat.
- Donations: Binance Pay and USDT (TRC-20).
- GPL-3.0 license, CI releases, CodeQL analysis, unit tests, update checker,
  weekly automated engine bumps with smoke tests.
