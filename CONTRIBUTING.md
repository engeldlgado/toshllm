# Contributing to ToshLLM

Thanks for your interest! Contributions are welcome under the project's
[GPL-3.0 license](LICENSE) — by submitting a pull request you agree that your
contribution is licensed under the same terms.

## Getting started

```bash
git clone https://github.com/engeldlgado/toshllm
cd toshllm
./scripts/build-engines.sh   # one-time: builds the patched llama.cpp engines
./make-app.sh                # builds and packages dist/ToshLLM.app
open dist/ToshLLM.app
```

Requirements: macOS 14+, Xcode Command Line Tools, CMake. No Xcode project —
the app is plain Swift Package Manager (`swift build`).

> **Note on tests:** Command Line Tools do not ship XCTest, so `swift test`
> requires a full Xcode install (or just rely on CI, which runs the suite on
> every push and pull request).

## Project layout

| Path | Purpose |
|---|---|
| `Sources/` | SwiftUI app (one file per concern: Server, Models, Chat, Benchmark…) |
| `Assets/` | App icon source, web chat UI, donation QR |
| `patches/` | AMD Metal patches applied on top of upstream llama.cpp |
| `scripts/` | Reproducible engine build + DMG packaging |
| `.github/workflows/` | CI: build on push, DMG release on tags |

## Guidelines

- **Target hardware is Intel Mac + AMD dGPU.** Test changes against a real
  Metal AMD setup when they touch the engine, server flags or memory logic.
- **Bilingual UI**: every user-facing string goes through `loc.t("es", "en")`.
  Both languages are required, and every new setting needs a `.help` tooltip.
- **No new dependencies** without prior discussion — the app is intentionally
  dependency-free (SwiftPM with zero external packages).
- Keep the memory **estimator honest**: if you change `Estimator`, include the
  measurements that justify the new formula in the PR description.
- Engine changes go in `patches/` as diffs against the pinned llama.cpp commit
  (see `scripts/build-engines.sh`), never as vendored sources.

## Reporting issues

Include: macOS version, GPU model and VRAM, RAM, the model + quant you ran,
your Settings (a screenshot works), and the server log (Settings → Server log).
