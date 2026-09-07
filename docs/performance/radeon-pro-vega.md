# GCN

Measurements for GCN cards: Vega, Radeon VII and RX 400/500. They are kept apart from the RDNA
numbers because the two are different silicon and, as the tables below show, the same setting
can help one and cost the other.

The work behind these figures gave these cards kernels of their own, in their own source
files, instead of running code laid out for RDNA. The RDNA path never loads them,
so nothing here changes what those cards do.

## How this was measured

A Radeon Pro Vega II Duo, against the published 0.86.6 binary, so the comparison never needs
a rebuild. Every number is `llama-bench` with flash attention on and the model held in
memory, three alternating rounds of old and new inside the same run, and a result is only
accepted when the two ranges do not overlap. The machine's clock drifts between sessions, so
pairs that are hours apart cannot be compared.

Correctness was checked the same way each time: the whole operator suite has to come back
with nothing failing, and perplexity has to match the published binary digit for digit.

## Generating text

One model per quantization type, `tg128`, tokens per second.

| Quantization | 0.86.6 | Now | Change |
|---|---|---|---|
| MXFP4 | 23.90 | **48.97** | +104.8% |
| Q8_0 | 60.84 | **91.72** | +50.7% |
| IQ1_M | 40.50 | **58.02** | +43.2% |
| Q6_K | 65.15 | **80.02** | +22.8% |
| Q5_K | 69.19 | **80.21** | +15.9% |
| Q4_K | 79.33 | **88.49** | +11.5% |
| Q5_0 | 78.61 | **87.35** | +11.1% |
| IQ3_XXS | 49.64 | **55.09** | +10.9% |
| Q2_K | 65.26 | **72.31** | +10.8% |
| Q4_1 | 91.43 | **101.02** | +10.4% |
| IQ1_S | 57.55 | **63.28** | +9.9% |
| Q5_1 | 76.51 | **84.02** | +9.8% |
| Q3_K | 60.73 | **66.45** | +9.4% |
| IQ4_NL | 61.59 | **67.32** | +9.3% |
| Q4_0 | 99.44 | **108.47** | +9.0% |
| IQ3_S | 43.81 | **47.38** | +8.1% |
| IQ4_XS | 62.13 | **66.44** | +6.9% |
| IQ2_XXS | 57.37 | 58.69 | +2.3% |
| IQ2_S | 53.01 | 53.10 | +0.1% |
| IQ2_XS | 54.57 | 54.25 | -0.5% |

Seventeen of the twenty types gain, thirteen of them by more than 9%. The three that do not
are all in the IQ family below three bits, where the cost is arithmetic rather than memory,
so reading fewer bytes per lane buys nothing. Perplexity is unchanged on all twenty.

MXFP4 is the outlier for a plain reason: it was falling off a cliff at two rows per group and
now keeps four.

## Reading a prompt

One model, Qwen3-4B, in sixteen quantizations, at three prompt lengths. Prompt tokens per
second, and the change against 0.86.6.

| Quantization | 256 tokens | 384 tokens | 512 tokens |
|---|---|---|---|
| Q8_0 | 774 → **987** (+27.5%) | 871 → **1121** (+28.6%) | 975 → **1038** (+6.5%) |
| F16 | 1178 → **1379** (+17.1%) | 1277 → **1358** (+6.4%) | 1293 → **1374** (+6.3%) |
| Q5_0 | 898 → **904** (+0.8%) | 1022 → **1029** (+0.7%) | 813 → **1016** (+24.9%) |
| Q5_1 | 893 → 894 (+0.1%) | 1019 → **1024** (+0.5%) | 809 → **1003** (+24.0%) |
| Q4_0 | 995 → **1075** (+8.0%) | 1126 → **1218** (+8.2%) | 1171 → **1194** (+2.0%) |
| Q6_K | 856 → **877** (+2.4%) | 984 → **1020** (+3.6%) | 1014 → **1029** (+1.5%) |
| Q4_K_M | 1046 → **1057** (+1.0%) | 1172 → **1181** (+0.7%) | 1221 → **1259** (+3.1%) |
| Q3_K_M | 994 → **1002** (+0.9%) | 1095 → **1103** (+0.7%) | 1184 → **1214** (+2.5%) |
| Q5_K_M | 880 → **886** (+0.7%) | 987 → **994** (+0.8%) | 1067 → **1093** (+2.4%) |
| Q2_K | 956 → **963** (+0.6%) | 1094 → 1096 (+0.2%) | 1114 → **1141** (+2.4%) |
| Q4_1 | 975 → 972 (-0.3%) | 1101 → 1100 (-0.1%) | 1134 → **1156** (+1.9%) |
| IQ3_XXS | 898 → **908** (+1.2%) | 968 → **975** (+0.8%) | 1001 → **1018** (+1.6%) |
| IQ3_M | 906 → **914** (+0.8%) | 984 → **991** (+0.7%) | 1027 → **1045** (+1.7%) |
| IQ4_XS | 992 → **999** (+0.7%) | 1059 → 1055 (-0.3%) | 1063 → **1078** (+1.4%) |
| IQ2_M | 882 → **887** (+0.6%) | 973 → 976 (+0.3%) | 1003 → **1020** (+1.6%) |
| IQ4_NL | 917 → **921** (+0.4%) | 1006 → 1004 (-0.2%) | 1043 → **1055** (+1.2%) |

Across the 144 pairs the average is +4.1% and the middle of the range is +1.1%. Every one of the
sixteen types is unchanged or faster at every length measured; nothing falls below half a percent.

IQ4_NL took the longest to settle. The kernel that reads a prompt in 64-lane groups costs it 3.9%
at 256 tokens and gains it 1.2% at 512, so rather than lose the gain it has a floor of its own and
only uses that kernel past 384 tokens. Isolating it needed each change turned off separately:
switching off the wide tile left the loss untouched, switching off the 64-lane kernel removed it
exactly.

Q5_0 and Q5_1 look flat until 512 tokens because that is where the wide tile starts being
used at all. Q8_0 and F16 gain most at the short lengths, which is where the old tile was
worst.

## Where a setting is decided per type

The thresholds that pick the wide tile are not one number any more. A value that pays for
Q8_0 costs Q4_K, so each type carries its own. The floors that ended up different from the
default of 448 prompt tokens and 4096 output rows:

| Setting | Types | Value |
|---|---|---|
| Prompt tokens before the wide tile | Q8_0, Q6_K, Q5_K, Q4_1, Q3_K, IQ3_S | 192 |
| | Q4_0 | 256 |
| Output rows before the wide tile | Q8_0, Q4_0 | 2048 |

## What was not measured

The attention used while reading a prompt keeps its 16-lane groups and 64-key blocks. Both
were swept, and moving either one loses; the reason is reuse of the cached keys and values,
not register pressure. Padding the shared memory of that kernel was never tried and remains
the one open lead.
