# Thread sweep 2026-09-30: Qwen3-4B-Q6_K tensor+events, AVX1 build

| threads | pp512 | tg128 |
|---|---|---|
| 12 | 153.13 | 17.41 |
| 16 | 153.26 | 17.24 |
| 24 | 152.13 | 11.72 |

tg collapses at 24 threads (SMT contention, 12 physical cores). Default physical, cap at physical.
