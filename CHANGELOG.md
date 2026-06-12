# Changelog

All notable changes to ToshLLM are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/).

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
