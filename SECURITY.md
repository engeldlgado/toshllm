# Security Policy

## Supported versions

Only the latest release receives security fixes.

## Scope

ToshLLM runs entirely on-device. The built-in server (`llama-server`) binds to
`127.0.0.1` only and is never exposed to the network by default. The app makes
outbound connections exclusively to:

- `huggingface.co` — model downloads explicitly initiated by the user
- `127.0.0.1:<port>` — the local inference server

There is no telemetry, no analytics, and no account system.

## Automated checks

- **CodeQL** static analysis runs on every push (`.github/workflows/codeql.yml`).
- **Unit tests** run in CI on every push.
- **Dependabot** keeps GitHub Actions dependencies updated. The Swift package
  itself has zero external dependencies by design.
- Bundled engine binaries are built from source in CI from a **pinned upstream
  commit** plus the audited patches in [`patches/`](patches/) — never from
  prebuilt blobs.

## Reporting a vulnerability

Please open a [private security advisory](https://github.com/engeldlgado/toshllm/security/advisories/new)
or contact the maintainer via GitHub. Do not open public issues for
security-sensitive reports.
