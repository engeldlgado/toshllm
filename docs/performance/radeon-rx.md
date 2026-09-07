# RDNA

Measurements for RDNA cards: RX 5000 and later. They are kept apart from the GCN numbers
because the two are different silicon, and, as the tables here show, the same setting can be
worth 24% on one and cost 14% on the other.

## How this was measured

A Radeon RX 6700 XT, against the published 0.86.6 binary, so no comparison needs a rebuild.
Every number is `llama-bench` with flash attention on and the model held in memory, three
alternating rounds of old and new inside the same run, and a result is only accepted when the
two ranges do not overlap.

One model, Qwen3-4B, in sixteen quantizations, so that between types only the type changes.
Correctness was checked with the whole operator suite and, for anything touching the kernel that
generates tokens, with `MUL_MAT` specifically: perplexity runs its text in batches and never
calls that kernel, so it cannot see a fault there.

## Reading a prompt: two quantizations were paying for a tile they never use

The wide tile is worth 5% to 18% from 192 tokens up on fourteen of the sixteen types. On Q5_0
and Q5_1 it costs, at every length measured from 48 to 2048 tokens, and the single floor of 112
tokens turned it on for them anyway.

They now stay on the narrow path. Prompt tokens per second against 0.86.6:

| Quantization | 128 tokens | 256 tokens | 512 tokens | 1024 tokens |
|---|---|---|---|---|
| Q5_0 | **+17.2%** | **+12.2%** | **+6.8%** | **+5.5%** |
| Q5_1 | **+17.2%** | **+13.7%** | **+7.2%** | **+6.0%** |
| F16 | +0.1% | +0.0% | -0.0% | +0.1% |
| Q4_0 | -0.1% | -0.1% | -0.3% | -0.1% |
| Q4_K_M | +0.1% | +0.1% | -0.0% | -0.1% |
| Q8_0 | -0.0% | -0.2% | +1.1% | -0.0% |

The four rows below the line are controls: they were measured to confirm the change reaches only
the two types it names. None moves outside a third of a percent.

The same comparison was repeated on a Radeon Pro W6800X Duo, a workstation card of the same
generation but with different memory and none of the last-level cache the RX 6700 XT carries. It
reproduces, and by more: Q5_0 gains 19.2% at 128 tokens there against 17.2% here, and 8.1% at
1024 tokens against 5.5%. The controls stay still on both. The threshold belongs to the lane
width, not to one card.

The same quantizations gain 24% from the wide tile on GCN. A single threshold cannot
serve both, which is why they are set per type and per card family.

## Where the floor belongs

Turning the tile on earlier does not help. With the floor forced down to 32 tokens:

| Quantization | 48 tokens | 64 tokens | 96 tokens |
|---|---|---|---|
| F16 | -8.4% | -5.2% | -0.0% |
| Q8_0 | -10.1% | -6.7% | +0.2% |
| Q4_0 | -10.6% | -7.2% | +0.4% |
| Q5_0 | -29.9% | -27.3% | +0.5% |
| Q5_1 | -28.8% | -26.6% | +0.6% |

Below roughly a hundred tokens the tile loses for everything, so the shipped floor of 112 sits
where it should.

Whether to raise it is the one question two cards could not settle. At 128 tokens the RX 6700 XT
gains between 0.1% and 3.8% from the tile, while the W6800X loses between 0.8% and 2.5% on the
same types, and only F16 gains on both. Moving the floor to 192 would help one card and cost the
other by about the same amount, so it stays where it is. The likely difference is the
last-level cache that only one of the two carries, and settling it needs a third card rather
than a preference.

The shape holds outside Qwen3-4B. Gemma-4 12B gains 7.3% at 128 tokens and 11.2% at 512, its
smaller sibling 2.9% and 6.1%, and an OLMoE mixture 2.0% at 512, where less of the work goes
through this path.

## Generating text: nothing to gain, with one exception

Nineteen quantization types were swept over how many lanes share a block and how many rows each
lane carries, which is where the same sweep found 105% on the Vega cards. Here the shipped
defaults win almost everywhere. The one exception:

| Quantization | 0.86.6 | Now | Change |
|---|---|---|---|
| Q5_K | 85.6 | **88.2** | +3.0% |

Sixteen lanes to a block with two rows each, the same split that won on the other family. Its
neighbour at four rows gains 1.0%, so this is a plateau rather than a spike, and it reproduced
across two builds.

Everything else measured between -0.2% and -34%, so the defaults stay. MXFP4 is the clearest
contrast: on the Vega cards this sweep doubled its generation, and here no cell beats the
default at all.

## What else was measured, and left alone

Eight fronts were swept in all. Six of them found the shipped settings already right, which is
worth stating as plainly as the two that did not:

| Front | Result |
|---|---|
| Wide tile floor, per type | Two types changed, up to 17% |
| Lanes and rows in the matvec | One type changed, 3% |
| Expert matrix multiply floor | Already right; switching it off costs 4.7% to 7.4% |
| Flash attention tile, work groups, ext, graph optimizer | Nothing moves, thirty points within a tenth of a percent |
| Tail bound, f32 accumulator, `MM_MIN` | Nothing moves |
| Double buffering | Already on; switching it off costs 1.7% to 5.7% |
| Prompt micro-batch | 512 stays; doubling it gains 1% on three types and loses on a fourth |
| Prefill attention block sizes | Already right |

Two of those carry numbers worth keeping. The attention used while reading a prompt is worth
5.6% to 6.2% on a short prompt and **17.8% to 20.0% at a depth of 4096**, the largest single
contribution on this card. Double buffering the matrix multiply is worth more the wider the
data: 5.5% on F16 and 5.7% on Q5_0 against 1.8% on Q4_K_M.

The QKV fusion, worth 4.1% on the Vega cards, measures nothing here.

## Correctness

Perplexity and generated text were compared against 0.86.6 on all sixteen quantizations.

- Perplexity: identical to the last digit on all sixteen.
- Generated text: identical byte for byte on all sixteen, with the same prompt, temperature zero
  and a fixed seed. Sizes between 707 and 851 bytes, checked so that two empty replies cannot
  pass as a match.

The one operator that fails the suite, `TIMESTEP_EMBEDDING`, fails identically on the published
binary. It comes from upstream and touches nothing on this path.
