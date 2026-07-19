## Summary

<!-- What changed, and why is this the right solution? -->

Closes #<!-- issue number, or write "N/A" -->

## Scope and risk

<!-- Note the affected area, important tradeoffs, and anything reviewers should
     inspect carefully. Write "Low risk" for isolated documentation changes. -->

## Validation

<!-- List the commands or manual scenarios you ran and their results. If a check
     was not applicable or could not be run, say why. -->

**Hardware tested:** <!-- Mac, CPU, GPU(s), VRAM; or "hardware-independent" -->

**Models/settings tested:** <!-- Model, quant, context, ncmoe, DFlash, etc.; or "N/A" -->

- [ ] `swift test` passes
- [ ] `./make-app.sh` succeeds (app or packaging changes)
- [ ] `./scripts/build-engines.sh` succeeds (changes under `patches/` or engine build scripts)

## Contributor checklist

- [ ] The change is focused and does not include unrelated generated files or local data
- [ ] User-facing UI strings are bilingual (`loc.t("es", "en")`), with tooltips for new settings
- [ ] User-visible changes are documented in `CHANGELOG.md`
- [ ] Memory or performance claims include measurements and enough configuration to reproduce them
