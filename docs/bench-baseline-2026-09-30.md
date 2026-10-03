# Baseline 2026-09-30: 2x FirePro D700, Xeon E5-2697 v2, TOSH_NO_AVX2=1, engine 0.87.11

Env: GGML_METAL_CONCURRENCY_DISABLE=1 TOSH_FA_AMD=1, 12 threads, -ngl 99 --load-mode none -fa 1.

| model | mode | pp t/s | tg t/s |
|---|---|---|---|
| Qwen3-0.6B-Q8_0 | single MTL | 368.72 | 51.06 |
| Qwen3-4B-Q6_K | single MTL | 78.70 | 12.00 |
| Qwen3-4B-Q6_K | tensor none | 141.71 | 17.50 |
| Qwen3-4B-Q6_K | tensor peer | 141.85 | 17.49 |
| Qwen3-4B-Q6_K | tensor events | 153.26 | 17.48 |
| Qwen3-4B-Q6_K | tensor peer+events | 153.36 | 17.49 |
| Qwen3-4B-Q6_K | layer dual (DEVICES=2) | 78.45 | 11.96 |
| Qwen3-14B-Q4_K_M | layer dual (DEVICES=2) | 29.24 | 5.10 |

Notes:
- Layer split needs GGML_METAL_DEVICES=2 count var; DEVICE_LIST=0,1 alone leaves MTL1 closed on layer path.
- Tensor engages both GPUs; events +8pct prefill, peer inert (cards not bridged, peer group 0).
- tg flat across sync configs (wave64 CPU decode by design).
- maxBufferLength 3.5 GiB per D700.
