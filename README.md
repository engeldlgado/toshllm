<div align="center">

# ToshLLM

**Run large language models locally on Intel Macs with AMD GPUs.**

Native macOS app · Metal acceleration · No cloud, no accounts, no per-token costs

[![Build & Release](https://github.com/engeldlgado/toshllm/actions/workflows/build.yml/badge.svg)](https://github.com/engeldlgado/toshllm/actions/workflows/build.yml)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20(Intel%20%2B%20AMD%20GPU)-lightgrey)](#requirements)
[![Status: Beta](https://img.shields.io/badge/status-beta-orange)](https://github.com/engeldlgado/toshllm/issues)

### [⬇️ Download the latest release](https://github.com/engeldlgado/toshllm/releases/latest) · [📝 Changelog](CHANGELOG.md)

*[Versión en español más abajo](#toshllm-en-español)*

<img src="Assets/home.jpg" alt="ToshLLM home screen — hardware detection and model recommendations" width="760">

</div>

---

## What is ToshLLM?

ToshLLM lets you run modern open LLMs **entirely on your own Mac** — your chats never leave the machine, there are no accounts, and there's nothing to pay per token.

Most local-LLM tools on macOS only target Apple Silicon. Intel Macs with discrete AMD GPUs — including Hackintosh builds — get left behind: the stock engines produce **corrupted output** on AMD dGPUs and read model weights over PCIe at a fraction of the possible speed.

**ToshLLM fixes that.** It bundles `llama.cpp` built with AMD-specific patches and wraps it in a polished native SwiftUI app — so a card like the RX 6700 XT goes from unusable to genuinely fast:

| | Stock llama.cpp on AMD dGPU | ToshLLM |
|---|---|---|
| Output | corrupted | correct |
| Qwen3-8B generation | 0.6–2.6 t/s | **~57 t/s** |
| Qwen3.6-35B (MoE) generation | unusable | **~26 t/s** (with MTP) |

It opens, detects your hardware, and recommends models that will actually run well — no guesswork.

## Features

- **Native chat** — multiple persistent conversations, full Markdown with code-copy, regenerate, system prompt, live tokens/sec, file attachments
- **Model manager** — a curated catalog with **per-model VRAM/RAM estimates for *your* hardware**, plus Hugging Face search, downloads with live progress, and one-click delete
- **MoE-aware** — automatic `--n-cpu-moe` calculation so 35B-class Mixture-of-Experts models run well on 12 GB GPUs
- **MTP speculative decoding** — +34% generation speed with compatible models, zero quality loss
- **Dual engines** — official llama.cpp + experimental **TurboQuant** engine (KV cache down to ~16%, 100k+ token contexts on 12 GB VRAM), with an optional **AMD Flash Attention kernel** that keeps decode attention on the GPU for quantized/turbo KV (see the [research note](#research-amd-gpus-on-metal))
- **Benchmarks** — measure prompt/generation speed per configuration, with history and side-by-side comparison charts
- **OpenAI-compatible API** — use it at `http://127.0.0.1:8080`, with optional local-network access and Bonjour discovery
- **Multiple servers** — run several independent engine instances at once from the Dashboard, each with its own model, GPU, port and profile; serve different models side by side or pin one model per GPU
- **Every parameter explained** — bilingual tooltips and built-in docs (English/Spanish)
- **Profiles, menu bar mode, auto-start** — save full configurations and switch with one click

### In testing 🧪

These are new and still being validated — enable them in Settings, but expect rough edges:

- **Remember conversations (disk cache)** *(experimental engine)* — persists each chat's KV cache so reopening it, or restarting the app, skips re-processing the prompt; the reload is byte-exact, and a long chat comes back in under a second instead of re-prefilling. Also pre-warms the cache for external clients (VS Code/Cline), so their first request skips the multi-minute cold prefill.
- **Prompt cache reuse** *(experimental engine)* — reuses the cache across mid-prompt edits (coding assistants) and trimmed reasoning instead of reprocessing. Fast but approximate; toggle it off in Settings for exact, reproducible output.
- **Split model across all GPUs** *(experimental, both engines)* — splits the model's layers over every detected GPU, for machines with multiple cards. Unvalidated on AMD/Metal so far; the UI flags it and it needs real multi-GPU testing.

### A native chat that stays out of your way

Persistent conversations, Markdown with one-click code copy, and a live tokens/sec readout so you always know how fast the model is going.

<div align="center">
  <img src="Assets/chat.jpg" alt="ToshLLM native chat" width="760">
</div>

### Models picked for your machine

ToshLLM reads your GPU and RAM and suggests models by use case — fastest, balanced, top quality, coding — each with an honest estimate of how it'll run. Browse a curated catalog or search Hugging Face directly.

<div align="center">
  <img src="Assets/models.jpg" alt="ToshLLM model manager" width="760">
</div>

### Measure it on your own hardware

The built-in benchmark runs prompt and generation tests for any configuration and charts them side by side, so you can find the sweet spot for your card.

<div align="center">
  <img src="Assets/benchmarks.jpg" alt="ToshLLM benchmarks comparison" width="760">
</div>

## Install

1. **[Download the latest `.dmg`](https://github.com/engeldlgado/toshllm/releases/latest)**, open it, and drag **ToshLLM** to Applications.
2. The app is fully self-contained — the inference engines ship inside the bundle. No Homebrew, no Python, nothing else to install.

> **First launch (Gatekeeper):** releases aren't notarized with an Apple
> Developer ID yet, so macOS blocks the first open. Go to
> **System Settings → Privacy & Security** and click **"Open Anyway"**, or run:
> ```bash
> xattr -dr com.apple.quarantine /Applications/ToshLLM.app
> ```
> You only need to do this once per update. Notarized releases are planned.

## Requirements

- macOS 14 or later
- An Intel Mac with an AMD GPU that supports Metal (developed and tuned on an RX 6700 XT 12 GB)
- 16 GB RAM minimum — 32 GB recommended for 35B-class MoE models

> **Hackintosh note:** AMD RDNA 2 dGPUs work great with the [NootRX](https://github.com/ChefKissInc/NootRX) kext providing Metal support. ToshLLM runs on top of any working Metal setup.

## Good to know

ToshLLM is **beta** and under active development. It's solid for daily use, but you may still hit rough edges — please report anything you find in [Issues](https://github.com/engeldlgado/toshllm/issues) (you can export diagnostics from **Settings → Server log**). Two limitations are worth knowing up front:

- **External clients (VS Code Copilot, Cline, Continue…):** these send a fixed 15–19k-token prompt (system instructions + tool definitions) with *every* request. On GPUs without Metal Flash Attention that means minutes of prompt processing per cold request, which saturates the GPU and can thermally throttle it. Recent versions mitigate this (single slot with resumable prefill, prompt-cache reuse, inline reasoning) and more is on the way. The built-in chat isn't affected — it only sends your conversation.
- **Vision cache:** `llama.cpp` does not support saving/restoring slots or cache-reuse while an `mmproj` is loaded. ToshLLM disables those features automatically for vision models; normal in-memory prompt caching still works.
- **Large MoE models on AMD GPUs:** Mixture-of-Experts models that don't fully fit in VRAM (e.g. 26B/35B with `--n-cpu-moe` offload) shuttle data between GPU and CPU on every token. On discrete AMD GPUs under Metal this can eventually deadlock the driver mid-generation. ToshLLM ships a **watchdog** that detects the stall, frees memory, and suggests switching to a dense model. **Dense models (e.g. 8B, fully in VRAM) are stable and recommended**; large MoE-with-offload is best avoided. *(Characterized on an RX 6700 XT with the [NootRX](https://github.com/ChefKissInc/NootRX) kext; behavior may differ on other AMD setups.)*
- **Vision (image input):** on large MoE / K-quant models (e.g. Qwen 3.6 35B) the **bundled engine** can emit garbage (`0000…`) because attention falls back off the GPU. The **experimental engine** fixes this — selecting it turns on the **AMD Flash Attention kernel** by default, which keeps attention on the GPU and produces correct descriptions. The exception is **Gemma 4 (MoE)**, whose image encoder still crashes under forced Flash Attention on AMD: use the bundled engine for Gemma 4 vision.

## Build from source

Prerequisites: Xcode Command Line Tools (`xcode-select --install`), CMake.

```bash
git clone https://github.com/engeldlgado/toshllm
cd toshllm
./scripts/build-engines.sh      # clones llama.cpp, applies AMD patches, builds static engines
./make-app.sh                   # builds the SwiftUI app and packages dist/ToshLLM.app
./scripts/make-dmg.sh v0.81.1   # optional: create an installable DMG
./scripts/test.sh               # optional: run the unit tests (needs Xcode for XCTest)
```

The AMD patch lives in [`patches/`](patches/) — chunked staging transfers for Metal drivers that cap host-visible allocations (now also covering the asynchronous tensor read path that MTP exercises, which previously aborted mid-generation). The other key stability setting (`GGML_METAL_CONCURRENCY_DISABLE`) is already supported upstream and the app sets it automatically.

## Research: AMD GPUs on Metal

### Flash Attention (decode)

A recurring limitation on discrete AMD GPUs under Metal is that **Flash Attention** is gated on hardware features these GPUs report as unavailable (`simdgroup matrix multiply`), and the upstream "vec" decode kernel miscompiles on RDNA 2 (it produces garbage even though each SIMD primitive is correct in isolation). The practical consequence: any quantized or `turbo*` KV cache **requires** Flash Attention, so on AMD that attention silently falls back to the CPU and generation collapses at longer contexts.

ToshLLM ships a from-scratch **AMD decode attention kernel** (Metal) as an opt-in toggle on the experimental engine. It keeps a deliberately simple structure (one `float4` slice of the head per SIMD lane, simdgroups splitting the KV stream, online-softmax merge) that was validated bit-for-bit against a CPU reference. It supports head dims **128, 256 and 512**, KV types **f16, q8_0, q4_0 and turbo2/3/4** in **any keys/values combination** of the standard types (so you can compress keys while keeping values at full precision, all on the GPU), and is gated behind an environment flag so the default engine is unchanged.

The kernel splits the KV stream across as many simdgroups as the threadgroup-memory budget allows (32 for head dim 128, 16 for 256, 8 for 512 — the head dim Gemma 4's global layers use), turning the long serial decode loop into short parallel ones — a win that grows with context depth. On an RX 6700 XT with a turbo KV cache, generation at 4096 tokens of context improves from 19 → 33 t/s on an 8B (+75%) and 26 → 31 t/s on the 9B coder (+17%); at 2048 tokens, +42% and +11%. Prompt processing stays within ~3% and output is bit-for-bit unchanged.

Measured on an RX 6700 XT (decode, `tg`, llama-bench), GPU kernel vs the CPU fallback that quantized KV would otherwise force:

| Model / KV | context | CPU fallback | AMD kernel |
|---|---:|---:|---:|
| Qwen3-8B, f16 (head 128) | 1k | 7.1 t/s | **43.4 t/s** |
| Qwen3-8B, turbo3 (head 128) | 1k | 3.9 t/s | **30.3 t/s** |
| 9B coder, turbo3 (head 256) | 1k | 13.6 t/s | **30.8 t/s** |

The same kernel handles **prompt processing** too: although it is the "vec" decode kernel rather than the matrix-unit "mm" kernel a fully-equipped GPU would use for prefill, running it on the GPU still crushes the CPU fallback that quantized KV would otherwise force — and, unlike the CPU path, it stays flat with depth:

| KV (8B), prompt processing | pp2048 CPU | pp2048 AMD kernel |
|---|---:|---:|
| q8_0 | 40 t/s | **100 t/s** |
| turbo3 | 6 t/s | **97 t/s** |

It remains experimental and off by default. Vulkan/MoltenVK was also evaluated as an alternative backend and did not justify shipping (Metal wins on prompt throughput and matches generation).

### Quantized KV cache: memory vs speed

With the AMD attention kernel running on the GPU, quantizing the KV cache stops being a trap on these cards (it no longer forces attention to the CPU), so it becomes a real lever for fitting long context into limited VRAM. The experimental engine adds `q8_0` plus three `turbo2/3/4` types on top of `f16`. Measured on an RX 6700 XT with **Qwen3-8B (Q4_K_M)**, the hard case — prompt processing *and* generation on top of a 2048-token context (`pp2048 @ d2048`, `tg128 @ d2048`, llama-bench, cooled runs):

| KV type | pp @ depth (t/s) | tg @ depth (t/s) | KV at 32k ctx |
|---|---:|---:|---:|
| f16    | 120 | **54** | ~4.6 GiB |
| q8_0   | **195** | 53 | ~2.4 GiB |
| turbo4 | 184 | 38 | ~1.3 GiB |
| turbo3 | 166 | 36 | ~1.0 GiB |
| turbo2 | 188 | 41 | ~0.7 GiB |

Two things stand out. Prompt processing at depth is *faster* with a quantized cache than with `f16`, because attention reads a smaller KV (less bandwidth). And `q8_0` matches `f16` generation speed while halving the KV footprint — a free win for long context, and you can now quantize both keys and values, not just keys. The `turbo2/3/4` types trade ~25–30% generation speed for a far smaller cache (down to ~⅙ of `f16`); they earn their keep only when you are VRAM-bound and need a context that would not otherwise fit. *Quality at the lowest bit widths is not characterized yet.*

### ToshGEMM: tiled prefill matmul on AMD

Prompt processing on AMD was stuck on the slow matrix-vector path, because Metal's matrix-unit `mul_mm` kernel uses `simdgroup_matrix`, which AMD GPUs can't run (it crashes). **ToshGEMM** is a from-scratch tiled matrix-matrix kernel that restores the fast prefill without those cooperative ops. It is auto-selected on AMD RDNA (wave32); Apple Silicon and AMD GCN are unaffected, and it reverts with `GGML_METAL_MM_MANUAL_DISABLE=1`. Output is byte-identical and generation speed is unchanged.

Prompt processing on an RX 6700 XT (Qwen3-8B Q4, pp512, t/s, before → ToshGEMM):

| Engine | with Flash Attention | without FA (raw matmul) |
|---|---|---|
| Official | 93 → **228** (2.4×) | 99 → **342** (3.4×) |
| Turbo    | 105 → **309** (2.9×) | 99 → **322** (3.2×) |

For a 1000-token prompt that cuts time-to-first-token from ~10 s to ~4 s (official) and ~9 s to ~3 s (turbo).

ToshGEMM now also covers **Mixture-of-Experts** prefill: the per-expert matmul (`mul_mm_id`) uses the same tiled kernel, so MoE models get the speedup on whatever experts are GPU-resident, not just their dense/attention layers. On a Qwen3-Coder-30B-A3B (Q4_K_M, pp512, RX 6700 XT, `--n-cpu-moe 20`):

| path | pp512 (t/s) |
|---|---|
| matrix-vector (no ToshGEMM) | 90 |
| dense layers only | 102 (+12%) |
| dense **+ MoE experts** | **124 (+37%)** |

So the expert matmul adds the larger share (+22% on top of dense) once experts sit on the GPU. That share scales with how many experts fit in VRAM — small when most are offloaded to CPU (the usual case on 12 GB cards), larger on higher-VRAM GPUs. Output stays coherent. *Measured on a single RX 6700 XT; still needs more everyday-use testing across models and VRAM sizes.*

### Vega / GCN cards (in progress)

Older AMD GPUs (GCN: RX 500-series, Vega) use a 64-wide wavefront, while the simdgroup kernels assume 32 — that mismatch produces garbage output. An opt-in **wave64 safe mode** (`GGML_METAL_WAVE64_SAFEMODE=1`) routes the affected ops to correct (slower) fallbacks; it was confirmed coherent on an RX 580 by a tester, and is off by default so wave32 cards (Apple / AMD RDNA) are unaffected. A fast wave64 path (GCN has no simdgroup matrix or reduction, so it needs a custom kernel) is still being worked on — no benchmarks yet.

## Community benchmarks

Contributed by users running the built-in **Qwen3-4B (Q4_K_M)** benchmark on their own hardware:

| GPU | System | Prompt (t/s) | Generation (t/s) |
|---|---|---:|---:|
| Radeon RX 6900 XT 16 GB | Mac Pro 2019 — Xeon W 16-core, 96 GB DDR4 (genuine Mac) | 291.4 | 97.5 |
| Radeon RX 5600 XT 6 GB | Hackintosh — Core i5-12400F, DDR5 | 100.0 | 52.1 |

Running the **Qwen3-4B (Q4_K_M)** benchmark and sharing your numbers (GPU + system) in an issue is the easiest way to help — it grows this table for everyone.

## Architecture

```
ToshLLM.app
├── SwiftUI app (this repo) — UI, server lifecycle, downloads, estimator, benchmarks
└── Resources/
    ├── bin/        llama-server + llama-bench  (official, AMD-patched, static)
    ├── bin-turbo/  experimental TurboQuant engine (optional)
    └── test-ui/    minimal web chat served by llama-server
```

The app manages `llama-server` as a child process and talks to its OpenAI-compatible API. Hardware detection uses `sysctl` + Metal device enumeration; VRAM telemetry comes from IOKit.

## Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Please keep in mind the license below.

## License

**GPL-3.0** — see [LICENSE](LICENSE).

Free to use, study, modify and redistribute. Any distributed derivative must remain GPL-3.0 and preserve the copyright notice — the project can never be turned into closed-source commercial software.

## Credits

- [llama.cpp](https://github.com/ggml-org/llama.cpp) (ggml-org) — inference engine
- [iRon-Llama](https://github.com/Basten7/iRon-Llama-RC1) (Basten7) — Metal-on-AMD research for Intel Macs
- Developed by **Engelbert Delgado** ([@engeldlgado](https://github.com/engeldlgado))

## Support the project

If ToshLLM is useful to you:

- **Binance Pay**: alias `engeldlgado`
- **USDT (TRC-20)**: `TFUG271bbbQEmFu4wkFHyvNNkYRZC5JDUf`

---

## ToshLLM en español

**Ejecuta modelos de lenguaje grandes localmente en Macs Intel con GPU AMD.** Aceleración Metal. Sin nube, sin cuentas, sin costos por token.

### [⬇️ Descarga la última versión](https://github.com/engeldlgado/toshllm/releases/latest) · [📝 Cambios](CHANGELOG.md)

### ¿Qué es ToshLLM?

ToshLLM te permite ejecutar modelos LLM modernos **completamente en tu propio Mac** — tus chats nunca salen del equipo, no hay cuentas y no pagas por token.

Casi todas las herramientas de LLM locales en macOS apuntan a Apple Silicon; los Macs Intel con GPU AMD dedicada (incluidos los Hackintosh) quedan fuera: los motores estándar producen **texto corrupto** en estas GPUs y leen los pesos por PCIe a una fracción de la velocidad posible.

**ToshLLM lo resuelve.** Empaqueta `llama.cpp` con parches específicos para AMD dentro de una app nativa SwiftUI, de modo que una tarjeta como la RX 6700 XT pasa de inservible a realmente rápida (Qwen3-8B: de 0.6–2.6 t/s a ~57 t/s). Al abrirla detecta tu hardware y te recomienda modelos que correrán bien, sin adivinar.

### Funciones

- **Chat nativo** — conversaciones persistentes, Markdown completo con copiar código, regenerar, prompt de sistema, tokens/seg en vivo y adjuntar archivos
- **Gestor de modelos** — catálogo curado con **estimaciones de VRAM/RAM para *tu* equipo**, búsqueda en Hugging Face, descargas con progreso y borrado en un clic
- **Soporte MoE** — cálculo automático de `--n-cpu-moe` para que modelos de 35B corran bien en GPUs de 12 GB
- **Decodificación especulativa MTP** — +34% de velocidad de generación sin pérdida de calidad
- **Motores duales** — llama.cpp oficial + motor experimental **TurboQuant** (caché KV hasta ~16%, contextos de 100k+ tokens), con kernel opcional de **Flash Attention para AMD**
- **Benchmarks** — mide velocidad de prompt y generación por configuración, con historial y gráficas comparativas
- **API compatible con OpenAI** en `http://127.0.0.1:8080`, con acceso opcional por red local y descubrimiento Bonjour
- **Cada parámetro explicado** — tooltips bilingües y documentación integrada
- **Perfiles, modo barra de menú y auto-inicio**

#### En pruebas 🧪

Funciones nuevas, aún en validación — actívalas en Ajustes, pero pueden tener detalles por pulir:

- **Recordar conversaciones (caché en disco)** *(motor experimental)* — guarda la caché KV de cada chat, así al reabrirlo o reiniciar la app no se reprocesa el prompt; la restauración es byte-exacta y un chat largo vuelve en menos de un segundo. También pre-calienta la caché para clientes externos (VS Code/Cline), evitando el prefill frío de varios minutos en la primera petición.
- **Repartir el modelo entre varias GPUs** *(experimental, ambos motores)* — divide las capas del modelo entre todas las GPUs detectadas, para equipos con varias tarjetas. Sin validar aún en AMD/Metal; la UI lo advierte y necesita pruebas reales con multi-GPU.

### Instalación

Descarga el `.dmg` desde [Releases](https://github.com/engeldlgado/toshllm/releases/latest), ábrelo y arrastra **ToshLLM** a Aplicaciones. Todo viene incluido — sin Homebrew, sin Python.

> **Primer arranque (Gatekeeper):** las versiones aún no están notarizadas, así que macOS bloqueará la primera apertura. Ve a **Ajustes del Sistema → Privacidad y Seguridad** y pulsa **"Abrir igualmente"**, o ejecuta `xattr -dr com.apple.quarantine /Applications/ToshLLM.app`. Solo se hace una vez por actualización.

### Requisitos y notas

- macOS 14 o posterior · Mac Intel con GPU AMD compatible con Metal · 16 GB de RAM mínimo (32 GB recomendado para MoE de 35B).
- **Hackintosh:** las GPUs AMD RDNA 2 funcionan muy bien con el kext [NootRX](https://github.com/ChefKissInc/NootRX).
- **Beta:** funciona para uso diario pero pueden aparecer detalles por pulir; reporta lo que encuentres en [Issues](https://github.com/engeldlgado/toshllm/issues) (exporta diagnósticos desde Ajustes → Registro del servidor).
- **Limitaciones conocidas:** los clientes externos (VS Code, Cline…) envían un prompt fijo de 15-19k tokens en cada petición, lo que en frío satura la GPU varios minutos (el chat integrado no se ve afectado); y los modelos MoE grandes con offload pueden bloquear el driver AMD a mitad de generación — un watchdog lo detecta y recomienda cambiar a un modelo denso, que es lo más estable en este hardware.
- **Caché con visión:** `llama.cpp` no permite guardar/restaurar slots ni usar cache-reuse mientras hay un `mmproj` cargado. ToshLLM desactiva esas funciones automáticamente para modelos de visión; la caché normal en memoria sigue funcionando.

### Licencia

**GPL-3.0** — libre para usar, estudiar, modificar y redistribuir; cualquier derivado distribuido debe seguir siendo GPL-3.0 y conservar el copyright. El proyecto nunca podrá convertirse en software comercial cerrado.
