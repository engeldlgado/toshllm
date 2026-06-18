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
| `Assets/lang/` | Community UI translations — one JSON per language ([README](Assets/lang/README.md)) |
| `patches/` | AMD Metal patches applied on top of upstream llama.cpp |
| `scripts/` | Reproducible engine build + DMG packaging |
| `.github/workflows/` | CI: build on push, DMG release on tags |

## Guidelines

- **Target hardware is Intel Mac + AMD dGPU.** Test changes against a real
  Metal AMD setup when they touch the engine, server flags or memory logic.
- **Bilingual UI**: every user-facing string goes through `loc.t("es", "en")`.
  Both languages are required, and every new setting needs a tooltip
  (`.help` / `.infoTip`). Other languages are community JSON overlays — see
  [Translations](#translations).
- **No new dependencies** without prior discussion — the app is intentionally
  dependency-free (SwiftPM with zero external packages).
- Keep the memory **estimator honest**: if you change `Estimator`, include the
  measurements that justify the new formula in the PR description.
- Engine changes go in `patches/` as diffs against the pinned llama.cpp commit
  (see `scripts/build-engines.sh`), never as vendored sources.

## Translations

Spanish and English are built into the app via `loc.t("es", "en")`. Every other
language is a single JSON overlay in [`Assets/lang/`](Assets/lang/) that maps each
English string to its translation — adding one is drop-in and needs no Swift code.

Full instructions (how to add or update a language, the status of each one, and
how PRs are checked) are in **[`Assets/lang/README.md`](Assets/lang/README.md)**.

The short version for translators: open the language file and fill in the blank
values — every interface string is already listed and kept in sync for you.
Enable the auto-sync hook once and the rest is automatic:

```bash
git config core.hooksPath scripts/hooks
```

For maintainers touching the UI: the English template and the language files are
regenerated and synced automatically by that hook on each commit (new strings
added, removed ones dropped); CI re-checks it and skips when nothing changed.

## Reporting issues

Include: macOS version, GPU model and VRAM, RAM, the model + quant you ran,
your Settings (a screenshot works), and the server log (Settings → Server log).
