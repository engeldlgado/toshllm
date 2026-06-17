# Changelog

All notable changes to ToshLLM are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/).

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
- **KV cache guidance corrected for the AMD Flash Attention kernel** — with the kernel,
  use symmetric types (q8_0/q8_0 or q4_0/q4_0) for full speed; the q8_0-keys/f16-values
  combo falls back to the CPU. Tooltips and docs updated; kernel head-dim coverage now
  noted as 128/256/512 (Gemma 4).

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
