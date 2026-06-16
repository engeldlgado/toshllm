# Changelog

All notable changes to ToshLLM are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/).

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
