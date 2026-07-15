# Changelog

All notable changes to ToshLLM are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Removed
- **The experimental TurboQuant engine is gone** ... the bundled engine matches it (dense Qwen3-8B: 474 vs 475 pp, 60.3 vs 60.4 tg), and conversation persistence, previously exclusive to it, now works there.

### Fixed
- **The engine picker no longer flips to "External" on its own** ... it stored the engine's path, which differs between two installs sharing one settings domain.
- **Gemma 4 vision no longer crashes the server** ... forcing Flash Attention on used to split the projector graph and bind a null buffer; the projector now runs Flash Attention natively.

### Improved
- **Vision models now keep Flash Attention on the GPU**... describing an image costs 248-358 MB of VRAM instead of 3.4-4.7 GB, and the spike on the first image is gone.
- **Browse now reads each candidate's GGUF header** (#36)... the fit estimate sizes a MoE against expert offload even when its filename hides it, from one small range request per file.
- **The engine now stamps the ToshLLM version in its startup log**... a log pasted from a bug report identifies the build, which llama.cpp's own build number cannot do (it only tracks the upstream commit).

### Fixed
- **Model detection now uses GGUF metadata safely**... renamed MoE models keep correct VRAM estimates, split GGUFs act as one model, and legacy vision projectors pair only when unambiguous.
- **The Models tab now reflects your per-model expert offload**... its speed/fit estimate honors the saved ncmoe and shows it as a chip, matching what the server will run.

## [0.81.67] - 2026-07-14

### Improved
- **MoE prompt processing on GCN/Vega now uses the tiled matmul** (#29)... expert layers were still going through the mat-vec kernels during prefill; `TOSH_W64_MMID_PREFILL_DISABLE=1` in Extra arguments reverts to the old route.
- **Model names and speed estimates are clearer**... local GGUFs show readable titles, capabilities and quantization, while estimates now account for quant size and active MoE parameters.

### Fixed
- **Chat projects are easier to open and reorganize**... the whole project row responds to clicks, and conversations use a dedicated drag handle so moving them no longer conflicts with opening them.

## [0.81.66] - 2026-07-14

### Changed
- **The fast prefill route is now on by default for GCN/Vega cards** (#26, #29, #31; opt-in via `TOSH_W64_PREFILL=1` in 0.81.65)... validated on Vega II with identical perplexity and up to 2.8x at pp16384; `TOSH_W64_PREFILL_DISABLE=1` in Extra arguments turns it back off.

### Added
- **Projects in the chat sidebar**... folders that group conversations, pinnable like chats, with drag and drop and a shared system prompt.
- **System prompts per conversation and per project**... the conversation's wins, then the project's, then the global one; the parameters popover shows which applies.
- **Hourly update check**... the app silently re-checks while it stays open and lights the update badge; toggle in Settings.
- **Release notes in-app**... the Notes button now shows what changed from your version up to the latest in a popup; when up to date, the current version's notes (also from About, next to the version).

### Improved
- **The app icon is native on macOS 26**... rebuilt as a layered Liquid Glass icon (gradient background + chip glyph) with a rendered fallback for older systems.
- **The chat adopts the macOS 26 design language**... capsule and glass controls (new-chat, search, composer, project chips) using Liquid Glass on macOS 26 and translucent materials on 14-15.
- **The Benchmarks history stays smooth with long lists**... rows render lazily and skip redraws during runs.
- **Conversation titles**... smarter auto-titles and in-place renaming from the new header bar over the transcript.

### Fixed
- **Multi-GPU hand-off hardening** (candidate fix for #31)... the layer hand-off now drains the destination GPU before writing its input, and the fallback copy no longer issues an invalid cross-device blit.
- **Image generation no longer times out on eGPUs** (#33)... the image engine now gets the same private-VRAM buffer fix the LLM engine got in 0.81.30.
- **Chat text no longer cuts off with "…" on indented lines** at certain window widths (#32).

## [0.81.65] - 2026-07-13

### Added
- **`llama-perplexity` ships with the bundled engine**... numeric validation A/Bs no longer require building from source.
- **GCN/Vega cards can try the fast prefill route** with `TOSH_W64_PREFILL=1` in Extra arguments; it stays off there by default until testers validate it.

### Changed
- **The fast long-prompt prefill now covers every KV cache combination by default** (opt-in and keys-only in 0.81.64)... all f16/q8_0/q4_0 pairs take the route, worth up to +37% at pp4096 with fully quantized caches and growing with context (+90% or more at 16k); validated across head sizes 64-512 with no regression, and `TOSH_QK_PREFILL_DISABLE=1` in Extra arguments turns just this route off.

## [0.81.64] - 2026-07-13

### Added
- **Experimental: faster long prompts with quantized-key KV caches on AMD RDNA** (up to +54% at pp4096, generation and quality unchanged)... q8_0/f16 and q4_0/f16 caches take the decomposed-prefill route of 0.81.63 when `TOSH_FA_AMD_QKV_PREFILL_DECOMPOSED=1` is set in Extra arguments.

### Fixed
- **Row-sum and mean kernels no longer overflow their scratch memory on AMD GCN/Vega**, a silent-corruption risk for rows longer than 32 elements; the buffer now follows the hardware's real SIMD width. No change on other GPUs.
- **`GGML_METAL_WAVE64_SAFEMODE=1` now works as the app documents it**... the engine only read an internal name; it accepts both.

## [0.81.63] - 2026-07-12

### Improved
- **MoE auto-sweep leaves VRAM headroom**... it measures pp512/tg128, shows live samples and saves only the final recommendation, three `ncmoe` steps above the tight edge when safe.
- **MTP is automatic**... it activates only for GGUFs with an MTP head and offloaded MoE experts, avoiding measured regressions on full-GPU models.
- **Qwen3.5/3.6 decode uses one less Metal dispatch per GDN layer** by fusing SSM_CONV with its following SiLU activation.
- **Long-prompt prefill is faster on AMD RDNA** for head sizes 64/128/256/512 (up to 54% at pp4096), with no measured decode regression; quantized KV and wave64 keep Flash Attention.

### Fixed
- **MoE auto-sweep no longer hangs on verbose output** and now parses Metal VRAM sizes correctly.
- **BF16 decode is covered by the AMD wave64 GPU path** instead of falling back to CPU.

## [0.81.62] - 2026-07-11

### Improved
- **Mixed key/value quantized caches now run on the GPU on AMD**... a cache like q8_0 keys with f16 values (the recommended trade-off) was quietly falling back to CPU attention, because a same-type check rejected it before the AMD Flash Attention kernel could take it. That kernel handles keys and values independently, so mixed pairs now reach it. Measured on an RX 6700 XT, q8_0/f16 goes from CPU-fallback speed to 56 tokens/s, matching f16/f16. Works on both RDNA (wave32) and GCN/Vega (wave64) cards. Verified against the CPU reference across the key/value type matrix.

### Changed
- **The MTP toggle's help text now says where it helps**... multi-token prediction speeds up generation on MoE models with experts offloaded to the CPU, and can be neutral or a little slower on dense or full-GPU models. The tooltip reflects that, and the toggle still lets you enable it anywhere.

## [0.81.61] - 2026-07-11

### Improved
- **Qwen3.5/3.6 generation speed on AMD GCN/Vega cards (continued)**... the short convolution that runs in front of every Gated Delta Net layer was still executing on the CPU on wave64 cards, so each generated token crossed to the CPU and back for every one of those layers. That kernel needs no cross-thread reduction, so it now runs on the GPU with the rest of the layer. This is the piece 0.81.60 missed... the fused delta-net kernel moved to the GPU there, but the convolution beside it did not, which is why generation had not sped up on those cards. Verified numerically against the CPU reference; speed reports from GCN/Vega owners are welcome.

## [0.81.60] - 2026-07-11

### Improved
- **Qwen3.5/3.6 speed on AMD GCN/Vega cards**... the Gated Delta Net layers of these models now run their fused GPU kernel on wave64 cards (RX 500 series, Vega, Radeon VII) instead of the step-by-step fallback, which padded every generated token to a 64-token block. Since 0.81.58 these models were correct but slow on those cards; generation should now be several times faster. Verified numerically against the CPU reference; speed reports from GCN/Vega owners are welcome.

### Fixed
- **The MTP toggle no longer breaks models with a stripped MTP head**... many community quantizations remove the multi-token-prediction tensors but keep the metadata entry, and the app could read that as MTP support, making the server abort at startup with the toggle on. Detection now reads the metadata's real value, falling back to the tensor names, so only models that actually ship the head use speculative decoding.

## [0.81.59] - 2026-07-11

### Added
- **GPU Flash Attention for Llama 3.x and gpt-oss on AMD**... the AMD Flash Attention kernel now covers head size 64 and attention sinks, the two things these families needed, so their attention runs on the GPU instead of falling back to the CPU. Measured on an RX 6700 XT: gpt-oss-20b goes from 33.5 to 93.2 tokens/s with Flash Attention on (and now beats Flash Attention off, 90.3), Llama-3.2-1B from 72 to 250. Quantized KV caches ride the same kernel: gpt-oss with q4_0 keys and values holds 87 tokens/s. Verified against the CPU reference on 512 attention shapes.

### Fixed
- **Flash Attention no longer collapses to the CPU on uncovered models**... the AMD Flash Attention toggle used to force FA unconditionally, and any model the kernel didn't cover ran its attention on the CPU at ~3× the cost, silently. The toggle now lets the engine decide per model: GPU Flash Attention where the kernel covers it, cleanly disabled where it doesn't, the CPU path never. A quantized KV cache still forces FA on (the engine requires it), and setting Flash Attention to "on" manually keeps the explicit behavior.

### Deprecated
- **The experimental TurboQuant engine will be retired**... new improvements land in the official engine only, and the turbo2/3/4 KV quantization will be studied for integration there. The engine picker marks it, and selecting it shows a notice. It still works in this version.

## [0.81.58] - 2026-07-10

### Fixed
- **Qwen3.5/3.6 models no longer output garbage on AMD GCN/Vega cards**... on wave64 GPUs (RX 500 series, Vega, Radeon VII) the Gated Delta Net family produced endless repeated characters instead of text (#1, #25, #21). Two Metal kernels in that op chain assumed 32-lane SIMD groups: the cumulative-sum kernel read its group total from the wrong lane and wrote past its scratch memory, and the triangular solver left half the columns unsolved. Both now follow the hardware's real SIMD width, so these models run fully on the GPU on these cards. Other GPUs are untouched: on RDNA the fixed engine benchmarks identical to the previous release, output verified coherent across the whole model suite.
- **The integrated GPU is never picked automatically**... on Macs with an Intel iGPU next to discrete cards, macOS could hand the ~1 GB integrated GPU to the engine as the system default (typically when the display is on the internal port), which crashes with any real model. The engine now switches to the largest discrete card and says so in the log, multi-GPU splits count and use discrete cards only, and the VRAM estimator and the image tab's automatic GPU pick skip integrated GPUs. Selecting the iGPU explicitly still works, and iGPU-only Macs are unaffected.

## [0.81.57] - 2026-07-10

### Added
- **Encoder and VAE on a second GPU**... on multi-GPU Macs, each image instance can send the text encoder and the VAE to another card, leaving the main one entirely to the diffusion model, so bigger models or larger frames fit. The fit checks, the queue scheduling and the GPU warnings all account for the second card.
- **Queued prompts can target an instance**... a "Target" picker in the queue composer pins a prompt to one instance (its model, GPU and settings). A targeted prompt waits for its instance without blocking the rest of the queue, and the feed badges every entry with the instance that renders it.
- **Per-prompt reference image in the queue**... an optional "Image" chooser attaches an img2img source to the prompts you add with it, overriding the rendering instance's own reference for that run only. Pending entries show a small thumbnail of it.
- **List or grid results**... both the queue feed and the multi-instance canvas can switch between the full-width list and a grid whose columns adapt to the window width. Each view remembers its choice.
- **Save all from the queue feed**... one button copies every result of the session's gallery into a folder you pick, like the instances canvas already offered.

### Fixed
- **The queue's prompt box handles long prompts**... long text used to run off the right edge (or get cut off with no way to scroll) and didn't re-wrap when the window was resized. The box now wraps at its width, grows up to 8 lines and scrolls beyond that; Cmd+Return adds the prompt to the queue.
- **Chat and images on different GPUs no longer warn**... the "chat shares a GPU" notice only appears when the chat server could actually land on a card an image instance uses, so chat on one GPU and image instances on the others run together without noise.

### Improved
- **Results show their prompt and full details**... every instance tile and the single-instance canvas now display the prompt that made the image (hover for the full text) plus its real output size, format, seed and timing, and the queue composer keeps the target, seed and image options in one tidy row.

## [0.81.56] - 2026-07-09

### Fixed
- **The no-AVX2 build now really is AVX2-free**... the 0.81.54/55 "noavx2" downloads were still compiled with AVX2/FMA/BMI2 (the engine build system silently re-enables them unless each one is turned off explicitly), so on pre-AVX2 Xeons they crashed with the same illegal-instruction error (code 4) they were meant to fix. The legacy variant now pins an SSE4.2 baseline for all three engines (official, turbo and image).

### Improved
- **The server log identifies the running build**... the startup banner now says "no-AVX2 build" on the legacy variant, and an engine killed by an illegal instruction is diagnosed as a CPU-instruction mismatch pointing to the right download, instead of a bare "exited with code 4".

## [0.81.55] - 2026-07-09

### Added
- **GPU Flash Attention on AMD GCN/Vega cards**... the AMD flash-attention kernel now has wave64 variants, so on these cards (RX 500 series, Vega, Radeon VII) the attention itself... the last big piece that still ran on the CPU... moves to the GPU, including quantized KV caches. It engages automatically with Flash Attention on. First build with this on real GCN hardware, so reports are very welcome: if anything looks off, turning Flash Attention off returns to the previous behavior.

### Fixed
- **Legacy-quant models could output garbage on GCN/Vega**... on wave64 cards, dense models in the older quantization formats (Q4_0, Q4_1, Q5_0, Q5_1) were dispatched 64 lanes wide while their pipeline was still built 32 wide, corrupting the output in 0.81.54. K-quant models were not affected.

## [0.81.54] - 2026-07-08

### Added
- **Dedicated build for pre-AVX2 Macs**... older Mac Pros and Hackintoshes whose Xeons lack AVX2 (which made the normal app crash on launch with an "illegal instruction") now have their own download. It stays on its own update channel, so it never pulls a build that won't run on that CPU.
- **More of the model runs on the GPU on AMD GCN/Vega cards**... on wave64 cards (RX 500 series, Vega, Radeon VII) the GPU now also handles the legacy quantizations (Q4_0/Q4_1/Q5_0/Q5_1), the group/L2 normalization steps, and the Mixture-of-Experts expert math... all of which previously fell back to the CPU. Together with the existing K-quant path, most of a model's decode now runs on the GPU on these cards. It turns on automatically when a wave64 card is detected (set `GGML_METAL_WAVE64_DECODE_DISABLE=1` in Extra arguments to turn it off).

### Fixed
- **Image generation no longer runs out of memory at high resolutions**... the resolution limits now account for the fact that SD1.5/SDXL attention memory grows with the square of the image size, not linearly. Very large frames that the old estimate wrongly allowed (and that could crash the GPU) are now capped per model, so the offered sizes stay within what the card can actually render.

### Improved
- **Larger image queue previews and a multi-line queue prompt**... results in the Queue feed now show a large preview instead of a small thumbnail, and the queue's prompt box grows to several lines so longer prompts are easier to read and edit.

## [0.81.53] - 2026-07-08

### Added
- **Image studio: a prompt queue with a live feed**... a new "Queue" tab lets you line up prompts, each with its own seed, and the next free instance renders them one after another (one generation per GPU on AMD). A feed shows everything as it happens... queued, in progress, and finished results with their prompt, seed, size and time... so nothing is lost when an instance moves on to the next prompt.
- **Flux.2 klein 4B**... the lightest Flux 2 yet (step-distilled, 4 steps, Apache): a fast option that leaves more VRAM for larger frames. Available from 12 GB; Z-Image Turbo stays the recommended pick.
- **Custom and cinematic aspect ratios**... pick "Custom" and type a free W:H ratio (e.g. 21:9), or use the new 2.39:1 cinemascope preset. The long edge still respects the base size and the GPU's VRAM.
- **VRAM usage in the chat window**... the GPU-memory indicator now also rides in the chat window's toolbar, not only the configuration window and the menu bar.
- **Per-image "Save as…" and "Save all…"**... every result in a multi-instance run has its own save button again, plus a "Save all…" that copies every image into a folder you pick.
- **Delete images on app close**... an optional toggle clears generated images from the output folder when you quit, so the timestamped files don't pile up.

### Fixed
- **Multiple image instances no longer overwrite each other**... a batch generated in the same second shared one filename, so all instances pointed at a single image. Each output now gets a unique name.
- **The server card's "Advanced options" is responsive again**... the VRAM monitor's periodic refresh was rebuilding the whole Home view and stuttering the expand/collapse; it now updates only the GPU card.
- **Router chat always names a model**... the first message in router mode could go out with no model named and be rejected by the server; it now falls back to the first available model.

### Improved
- **Roomier multi-instance image layout**... several instances now stack vertically with a large preview and their timing and actions beside each image, instead of shrinking to thumbnails.
- **img2img ratio hint**... a note appears when the reference image's proportion differs from the chosen frame, which can crop the subject (e.g. cut-off heads in portraits).

## [0.81.52] - 2026-07-07

### Added
- **Router mode: one server, every model, no restart**... turn on "Router (multi-model)" on the server card (Home) and a single server auto-loads whichever model an OpenAI-compatible request names in its `model` field, unloading the previous one if needed. External clients (VS Code, Cursor, and generally anything speaking the OpenAI or Anthropic API format) and the built-in chat can switch models on the fly this way. A "Models loaded at once" setting controls how many stay resident. Both engines.
- **Pin and sort conversations**... pin any conversation to keep it at the top regardless of order, and sort the list by recent use, creation date, or title from a new menu next to the search field.

### Fixed
- **Image models now match their real VRAM tier**... a 16 GB GPU couldn't use models tagged for 16 GB, because macOS reports a bit less usable VRAM than the card's physical amount and the check required an exact match. The comparison now tolerates that gap.

### Improved
- Some other improvements and fixes.

## [0.81.51] - 2026-07-07

### Added
- **MoE prompt processing up to 4.4× faster**... for MoE models with experts in RAM (ncmoe > 0), expert weights are now streamed to the GPU through a second Metal queue that overlaps each upload with the compute of the previous chunk, and CPU-held experts keep their canonical layout so their matmuls can run on the GPU at all. Measured on the RX 6700 XT (prompt t/s): Qwen3.6-14B goes from 298 to 814, Qwen3.6-35B from 197 to 470, gemma-4-26B from 116 to 515, gpt-oss-20b from 57 to 184. Generation speed is unchanged at any context depth (gpt-oss even gains ~23%), vision prompts speed up too (+63% measured), and output is identical. The first prompt after loading a model pays a one-time buffer warm-up. New "MoE expert prefetch (prompt)" toggle in Settings, on by default; both engines. Builds on thecodacus' llama.cpp prefetch work, adapted to Metal. Full-GPU setups (ncmoe 0, e.g. multi-GPU splits with everything in VRAM) are not affected: their experts never leave VRAM.

## [0.81.50] - 2026-07-07

### Fixed
- **Qwen-Image no longer crashes at the end of generation**... its 3D VAE uses an operation (`IM2COL_3D`) that Metal doesn't implement, so the run aborted right at the decode step after minutes of sampling (#19). The VAE now runs on the CPU for this model automatically: decoding takes a few extra seconds and the image comes out. A Metal kernel to put it back on the GPU is planned.

### Changed
- **Clearer offload label**... the image studio's "VAE on CPU" toggle is now "Offload to CPU", which is what it always did (keep weights in RAM and stream them to VRAM per stage, to save VRAM). The Qwen-Image VAE fix above is independent and automatic.

## [0.81.49] - 2026-07-06

### Fixed
- **MoE models no longer slow down and freeze on long generations**... on AMD GPUs, MoE models with experts on the CPU (and multi-GPU splits) gradually lost speed during a long reasoning or vision answer and could end up freezing the engine, or the whole machine on some setups. Every per-token CPU↔GPU copy was creating a fresh kernel graphics resource and the AMD driver drowned in them. Those copies now reuse one persistent staging buffer, so sustained generations hold a flat speed indefinitely.

### Improved
- **MoE generation is much faster**... removing that per-copy overhead also raises steady-state MoE-offload speed: measured on the RX 6700 XT, Qwen3.6-35B goes from ~14 to ~21 t/s and the 14B from ~18 to ~22 t/s, with identical output. Multi-GPU splits use the same path and should see a similar gain.

## [0.81.48] - 2026-07-06

### Added
- **Parallel image instances**... the image studio can now run several generations at once. Each instance is a collapsible accordion with its own full configuration (model, prompt, size, GPU, steps, seed, format, img2img), so a multi-GPU Mac renders up to one variation per card from a single Generate. New instances inherit instance 1's prompt until you type their own, and the canvas becomes a grid with per-instance progress and results. Two instances on the same GPU show a warning (that can hang the card on AMD Macs).
- **Benchmark workload sizes**... two new fields choose how many prompt tokens (-p) and generated tokens (-n) the benchmark measures, while keeping every ToshLLM optimization active (#22). Defaults stay at the comparable pp512/tg128; each result records its sizes and the history labels non-standard runs.
- **Flux 2 image models**... the catalog adds Flux.2 klein 9B (Apache license, 4 steps, for 16 GB GPUs) and Flux.2 dev (the 32B quality reference, for 24 GB+ GPUs, non-commercial license). Both download from non-gated mirrors and sample with euler as upstream recommends; dev offloads idle models to CPU to fit. Fresh additions, feedback welcome.

### Fixed
- **Model switch updates the install panel**... picking a not-yet-downloaded image model now immediately shows its components and the download action, inline in the instance's form. Before, the panel could keep showing the previous model's state.

## [0.81.47] - 2026-07-06

### Added
- **Embeddings server**... a new option starts the server with `--embeddings`, so local RAG clients (e.g. Obsidian Copilot) get /v1/embeddings instead of a 501 error. Available in Settings and on each server card under the new Advanced options disclosure; pair it with a dedicated embedding model on a second server to keep chatting on the main one. Verified on AMD: GPU embeddings match the CPU reference exactly, including with the AMD Flash Attention kernel.
- **Pick exactly which GPUs share a model**... the GPU pickers on the server cards and in Benchmarks are now multi-select: check one GPU to pin it, check several to split the model's layers across exactly those cards, even non-adjacent ones (say, 0 and 6). Settings gains a 'Split GPUs' row when the multi-GPU split is on, and the main server card now shows the GPU selector on multi-GPU machines.
- **Paste images in the chat**... Cmd+V with a screenshot or a copied image attaches it to the message when the model has vision (all common formats); copied files attach like a drag-and-drop. Plain text pasting is unchanged.

### Fixed
- **Image generation GPU choice**... picking the first GPU in the list was silently ignored and generation ran on the system-default card instead. The selection now always pins the chosen GPU on multi-GPU machines.
- **Generated images keep their history**... each image now saves under a date-and-time name instead of overwriting the previous output file.

## [0.81.46] - 2026-07-04

### Added
- **Restart from Use**... pressing Use on a model while the main server is running now offers to restart it right away with the new model, after a confirmation popup. With the server stopped, Use keeps selecting the model without starting anything.

### Fixed
- **MoE offload follows the selected model**... picking a model from the server card or the benchmark now sets 'MoE experts on CPU' automatically: the value you last used for that model, or the hardware recommendation, and 0 for dense models. Before, the value from a previous MoE model stuck around (dense models kept showing MoE info) and selecting a MoE model didn't recover the value you had set.
- **Per-model MoE memory**... the app remembers the 'experts on CPU' you settle on for each model (adjusted in Settings, used in a benchmark run, or applied from the optimizer sweep) and restores it whenever that model is selected again, anywhere.

## [0.81.45] - 2026-07-04

### Fixed
- **MoE models no longer break on long prompts**... on AMD GPUs, mixture-of-experts models (Qwen3.6 35B/14B and family) could return garbage like `000000...` on a long prompt or from the second message on, and were silently losing prompt quality even when the output looked fine. The expert-routing matrix kernel read the wrong memory for every token past the first 128 of a batch (a Metal compiler quirk with 16-bit index math on AMD). Prompts now read correctly at any length, with a measured quality jump on long MoE prompts on top of the crash fix.

## [0.81.44] - 2026-07-03

### Improved
- **Faster prompt processing**... the AMD tiled matmul now does its math in packed half precision, which AMD cards run at twice the speed. Prompt processing jumps about 50% on both engines (Qwen3-8B: ~310 to ~470 t/s) with output quality verified identical. Generation speed is unaffected (that one is memory-bound).
- **Much faster prompts in long conversations**... a new attention kernel processes prompt tokens in groups of 16 that share the stored conversation instead of each token re-reading all of it. Prompt processing at 4K of context goes about 3x faster (103 to 289 t/s on an 8B), and the deeper the chat, the bigger the win... long conversations stop feeling slower to respond over time.

## [0.81.43] - 2026-07-02

### Added
- **Image generation studio**... a new experimental Images tab in the main window generates images locally on the GPU with stable-diffusion.cpp, which shares the same Metal stack as the language engines. Supports text-to-image and image-to-image (pick a starting image and set how strongly it steers the result), and runs on the AMD GPU with the same tiled matmul the language engines use.
- **Image model catalog**... a set of models spanning GPU sizes, each with its own VRAM budget so the app only offers the ones that fit, from small models on 4 GB cards up to larger ones on 24 GB+ cards. Resolution options scale to the selected model and the detected VRAM.
- **Custom image models**... point the studio at your own checkpoint, VAE and text-encoder files to run models beyond the built-in catalog.
- **Pick how many GPUs to use**... on a multi-GPU machine a setting chooses how many GPUs to split a model across instead of always using every detected GPU.
- **Image engine logs**... the Logs tab now switches between the server log and the image generation log.

### Changed
- **Newer bundled engine**... updated the bundled llama.cpp to a recent master build.

## [0.81.42] - 2026-06-27

### Changed
- **AMD Flash Attention defaults to GPU**... the AMD kernel is now on by default for bundled engines and is restored when switching back to bundled or TurboQuant, so supported AMD runs prefer the custom GPU path instead of the standard CPU Flash Attention path.
- **Clear Flash Attention labels**... settings and benchmarks now distinguish the standard `Flash Attention (CPU)` path from the `AMD Flash Attention (GPU)` kernel without burying the distinction in tooltips.

### Fixed
- **Quantized KV benchmarks**... any quantized KV cache now forces `-fa 1` for server and benchmark runs, as llama.cpp requires, while leaving `TOSH_FA_AMD` under the AMD kernel toggle. Turning the AMD kernel off still allows the standard CPU Flash Attention fallback for compatibility and comparison.
- **Benchmark history**... each benchmark now records and displays whether it used `FA CPU`, `FA AMD GPU`, `FA auto` or no Flash Attention, and the full text log includes the effective FA route for shareable results.

## [0.81.41] - 2026-06-27

### Fixed
- **AMD Flash Attention toggle**... the app no longer turns on Flash Attention implicitly when switching engines or using quantized KV values. Standard Flash Attention and the AMD GPU kernel now follow their own controls: `-fa` stays off when Flash Attention is off, and `TOSH_FA_AMD` is only set when the AMD kernel toggle is enabled.

## [0.81.40] - 2026-06-27

### Added
- **AMD Flash Attention on the bundled engine**... the custom AMD attention kernel, until now only on the experimental engine, runs on the default bundled engine too, keeping attention on the AMD GPU instead of the CPU. A toggle sits right next to the standard Flash Attention setting, with a clear distinction: standard Flash Attention runs on the CPU on AMD GPUs, the AMD kernel runs on the GPU. On an 8B this lifts generation from ~12 to ~58 t/s. Covers standard KV (f16/q8_0/q4_0) and head dims 128/256/512.

### Fixed
- **Vision detection**... a text model no longer shows as vision-capable just because an unrelated projector with a matching size happens to sit in the same models folder. A projector is paired only when its name matches the model (the `<model>.mmproj.gguf` or `mmproj-<model>.gguf` convention), so models like Qwen3-8B stop borrowing another model's `mmproj`.

### Changed
- **Vision-capable models**... confirmed image input working with the AMD Flash Attention kernel across the Qwen3-VL family (Qwen3-VL-2B, Qwen3.5-9B, Qwen3.6-14B/35B) and Gemma 3, with Gemma 4 on the bundled engine. The Qwen3-VL-2B recommendation now notes it can be unpredictable on long replies.

## [0.81.39] - 2026-06-24

### Fixed
- **Image input on the experimental engine**... picking the experimental engine now turns on the AMD Flash Attention kernel by default, which fixes garbage output (`0000…`) on large MoE / K-quant vision models. Gemma 4 vision still needs the bundled engine.
- **Update cleanup**... the downloaded `.dmg` is removed after a successful install instead of piling up in Downloads; it's kept if the update fails.
- **Recommended models**... replaced the Moondream2 vision pick (its chat template can't carry an image through llama-server, so every image returned HTTP 400) with Qwen3-VL-2B, a tiny vision model that works on both engines.

## [0.81.38] - 2026-06-23

### Improved
- **Disable thinking actually sticks**... turning reasoning off (or typing `/no_think`) now forces the model to stop thinking even on templates that ignore the flag, instead of spending the whole budget reasoning.
- **Multi-GPU recommendations**... model suggestions count combined VRAM when the split is on, so large models show as full-GPU instead of suggesting CPU offload.

## [0.81.37] - 2026-06-23

### Added
- **Per-GPU VRAM on the Dashboard**... a new GPUs card shows a usage bar for each detected
  GPU, so multi-GPU machines see what each card is holding instead of a single guessed total.
- **VRAM in the menu bar**... a new setting shows VRAM usage next to the menu bar icon
  (aggregate percentage) or as per-GPU bars inside the panel.
- **Consolidated menu bar panel**... it now lists every server, the main one first, each with
  its own start/stop, a chat link while running, and its own "discoverable on network" toggle.

### Changed
- **Networking toggle applies live**... turning "discoverable on local network" on or off now
  restarts the running server automatically to apply it, instead of staying disabled until you
  restart by hand.
- **Add-server button**... it now gives press feedback and scrolls to the new card, so a click
  always produces something visible.

### Fixed
- **Per-GPU VRAM reading**... the monitor read only the first accelerator, so a second GPU's
  usage was missing; each GPU is now paired to its accelerator by registry ID.
- **Independent KV slot caches**... each server's on-disk KV slots now live in a per-port
  folder, so servers with cache persistence no longer overwrite each other's slot files.

## [0.81.36] - 2026-06-22

### Added
- **Multiple servers at once**... run several independent engine instances from the
  Dashboard, each with its own model, GPU, port, profile and vision/network toggles. Add
  one with the floating button, remove it with the x. Handy for serving different models
  side by side or pinning one model per GPU. The chat keeps using the main server.
- **Per-server logs**... the Logs tab gets a picker to switch between each running server's
  live log.
- **Model picker on the main server card**, alongside the one the added servers already had.

### Fixed
- **Cleaner shutdown of multiple engines**... the engine tracker now records every running
  instance, so each one is reaped on quit instead of only the last.

## [0.81.35] - 2026-06-22

### Added
- **Text-only toggle for vision models** — vision-capable models now show an eye control on
  the Dashboard. Turn it off to run the model as text-only and free the VRAM its image
  encoder would otherwise use.

### Fixed
- **Multi-GPU split activation hand-off** — the cross-device copy in a layer split used
  an invalid Metal blit (a blit can't reach another device's buffer); it now stages
  through host memory. This targets the corrupted generation reported on dual-GPU setups.
  Applies to both engines. (Advanced: `GGML_METAL_CROSS_STAGING_DISABLE=1` uses the
  generic fallback copy.)

## [0.81.34] - 2026-06-22

### Improved
- **Reproducible benchmarks** — each run records the GPU it used and a full
  configuration snapshot, and any run (not just the last) can be saved as a profile.
- **Benchmark profile picker** — seed a benchmark from a saved profile, apply a result
  to the global default, or save it as a new profile; the history highlights your best
  run and lets you save, apply or delete any row.
- **Profiles on the Dashboard** — the server card shows the active profile in a picker at
  its top-right, with a "Default (no profile)" entry that restores the configuration you
  had before applying any profile.
- **Benchmark history on disk** — runs are written to a shared `benchmarks.txt` with a
  full header (model, GPU, engine, args) for sharing or debugging, kept for 3 days.

### Fixed
- **"Logs in Finder" opens the logs folder** instead of a generic user folder.
- **Crash-safe logs** — log and benchmark writes are flushed to disk immediately, so a
  machine freeze no longer loses the recent history.
- **Models list populates at launch** — no need to re-select the models folder to see them.
- **"Reset to defaults" reverts the engine** from Turbo back to Bundled.

## [0.81.33] - 2026-06-21

### Improved
- **ToshGEMM now accelerates MoE prefill** — the per-expert matmul uses the tiled
  kernel too, so Mixture-of-Experts models speed up on their GPU-resident experts,
  not just dense layers (about +22% on top of the dense gain when experts sit in VRAM).
- **Benchmark: MoE expert-offload control** — adjust "MoE experts on CPU" directly in
  the Benchmark for MoE models, alongside Find-optimum.

### Fixed
- **An incompatible projector no longer blocks a model** — if a paired mmproj fails to
  load, the model now starts text-only instead of refusing to launch, and that pairing
  is remembered so it isn't retried (a different projector for the model still works).
- **MoE expert control hidden on dense models** — the "MoE experts on CPU" setting is
  disabled for non-MoE models, where the engine ignores it anyway.

### Changed
- **TurboQuant weight models (tq3_1s/tq4_1s) are blocked for now** — they decode to
  incorrect output on this engine, so the app refuses to load them with a clear message
  instead of producing garbage. Standard quants are unaffected.

## [0.81.32] - 2026-06-21

### Improved
- **Faster prompt processing on AMD (ToshGEMM)** — a new tiled matmul kernel replaces
  the slow fallback path, ~2.4–3× faster prefill / time-to-first-token on AMD GPUs.
  Output and generation speed are unchanged; auto-enabled on AMD RDNA.

### Fixed
- **Multimodal projector (mmproj) pairing** — each model now pairs only with a
  compatible projector, so vision models no longer fail to load by grabbing the wrong one.
- Minor fixes to profile saving.

## [0.81.31] - 2026-06-20

### Improved
- **Chat UI improvements and better chat performance**: smoother streaming, a
  rewritten transcript scroll with reliable auto-follow and scroll-to-bottom, a
  live prefill status, and assorted polish.

### Added
- Optional **smooth typing** animation (Settings).

### Fixed
- Chat no longer blanks out when switching or reopening conversations.
- A reply being generated no longer appears in other conversations.
- Concurrent requests share one KV pool, so extra slots don't shrink the chat's
  context window.

## [0.81.30] - 2026-06-20

### Added
- **GCN/Vega (wave64) safe mode**, opt-in on the official engine: type
  `GGML_METAL_WAVE64_SAFEMODE=1` in Extra arguments (any `KEY=VALUE` there is now passed
  as an engine env var). Validated coherent on an RX 580; off by default, no-op on
  Apple/RDNA. Extra arguments now route uppercase `KEY=VALUE` tokens to the environment.
- **Per-session server logs** with date-and-time filenames (survive a crash) that
  auto-delete after 3 days, plus a self-contained log header (version, engine, model,
  GPUs, args/env). Start/stop the server and pick a model from the Logs tab.
- **System info on the dashboard**: Mac model and macOS version.
- **Reset options to defaults** button (keeps models and the models folder).

### Fixed
- **eGPU full speed**: forces VRAM-resident buffers on external GPUs (was streaming over
  Thunderbolt at ~0.8 t/s), automatically when an eGPU is selected, with a manual toggle.
- CPU-threads selector capped to the machine's actual thread count.
- Port no longer shows a thousands separator (8080, not 8.080).

### Changed
- UI polish: dashboard cards aligned to equal height, server quick-settings (port,
  discoverability) without layout jumps, cleaner model estimate rows.

## [0.81.29] - 2026-06-19

### Fixed
- **External GPUs (eGPU) run at full speed.** The Metal backend forces shared
  (system-memory) buffers for external GPUs, so weights stream over Thunderbolt every
  op (~0.8 t/s). ToshLLM now forces private, VRAM-resident buffers
  (`GGML_METAL_SHARED_BUFFERS_DISABLE`) automatically when an external GPU is selected,
  with a manual "VRAM-resident weights" toggle (shown only when an eGPU is present) for
  the default case where macOS picks the eGPU. Likely also clears the
  `failed to decode prompt batch (res = -3)` benchmark error on eGPUs.

### Added
- **Self-contained server log header.** Each server start now logs the app version,
  engine, model, detected GPUs (flagging external/eGPU), the GPU selection, the resolved
  settings and the exact args/env (API key redacted) — so a single pasted log is enough
  to debug a remote setup.

## [0.81.28] - 2026-06-19

### Added
- **Real GPU selection and multi-GPU split on Metal.** The bundled Metal backend always
  used the macOS system-default GPU and ignored the picker; both engines are now patched
  so the GPU picker pins the engine to the exact physical card and "Split across all GPUs"
  registers every physical GPU so a model's layers can actually span separate cards. The
  default path (no selection, no split) is unchanged. Cross-GPU split on AMD/Metal is still
  experimental and unvalidated — keep an eye on coherence and stability.
- **Verified vision catalog picks** from the ggml-org multimodal collection: Moondream2
  (tiny/fast) and Pixtral-12B (strong OCR), alongside a small Gemma-3-4B vision pair.

### Fixed
- **Failed downloads can be retried.** A retry button now appears inline on a failed
  download (catalog and search results), instead of leaving the card stuck on "Error" with
  no way back to the download action.
- **Multimodal projector (mmproj) detection is reliable.** Projectors are saved under a
  model-specific name (`<model>.mmproj.gguf`) instead of the generic, collision-prone repo
  name (e.g. `mmproj-F16.gguf`), so pairing is unambiguous even with several models in one
  folder, and deleting a vision model removes its projector too. The auto-fetch now prefers
  q8/f16 projectors over bf16/f32 on AMD/Metal.

### Changed
- **Unverified vision is clearly flagged.** Vision models outside the curated catalog show
  a visible "Unverified" badge and an inline warning (no hover required) that the
  auto-selected projector's compatibility isn't guaranteed.

## [0.81.27] - 2026-06-19

### Added
- **Optional local-network API discovery.** A new toggle in Settings and the menu-bar
  panel binds the server to the LAN and advertises `ToshLLM API` through Bonjour. It is
  off by default, requires a server restart, and warns when API-key protection is off.
- **LAN and multimodal API guidance** in the built-in bilingual documentation, including
  local-network URLs, `/v1/models`, OpenAI `image_url` input and vision-cache limitations.

### Fixed
- **Multi-GPU benchmarks now use every selected GPU on both engines.** Benchmark runs
  inherit the server's GPU, KV-cache, Flash Attention and MoE options, including
  `--split-mode layer`, instead of silently using an independently-built argument list.
- **Vision models no longer trigger unsupported slot operations.** ToshLLM skips disk
  slot persistence, prewarming and cache-reuse when an `mmproj` is loaded, preventing
  `This feature is not supported by multimodal` errors from `llama.cpp`.

## [0.81.26] - 2026-06-18

### Added
- **Vision / Coder / MoE badges and filters in the catalog.** Models are tagged and
  the Models tab can filter by All / Vision / Coder / MoE. Hugging Face search results
  show a "Vision" badge when expanded (if the repo ships a multimodal projector).
- **Automatic vision-projector download.** Downloading a vision model also fetches its
  `mmproj` automatically. If a vision model is already downloaded but its projector is
  missing, a "Download vision file" button on its card gets it.
- **Retry button** for failed model downloads.

### Changed
- **Chat parameter tooltips match Settings** — Reasoning, Creativity, Response tokens
  and the system prompt now use the same pinnable ⓘ info popovers as Settings.

## [0.81.25] - 2026-06-18

### Added
- **Attach PDFs, scanned PDFs and more file types in chat.** PDF text is extracted
  automatically; scanned PDFs (no text layer) are read on-device with OCR. Text files
  in more encodings are accepted, and other binaries contribute their readable strings.
- **Image input for vision models (experimental).** If the loaded model has a paired
  multimodal projector (an `mmproj-*.gguf` next to it), you can attach images and ask
  about them; the projector is detected and loaded automatically on both engines. The
  vision encoder runs partly on the CPU on AMD GPUs (some Metal ops unsupported), so it
  works but isn't fully GPU-accelerated.
- **Configurable models folder.** Choose where models are downloaded and scanned
  (Settings → Application), instead of the fixed `~/models`.

### Changed
- **Higher chat response cap.** The response-token options now go up to the full
  configured context (e.g. 16k at the default, 32k+ when you raise the context).
- **Clearer "context full" handling.** Large attachments now warn before sending (with
  an estimate vs the context size), and the message explains it counts files + history.

### Fixed
- Multi-file attachment errors are now reported per file instead of a single generic line.

## [0.81.24] - 2026-06-17

### Fixed
- **Crash with prompt cache reuse + quantized KV.** A KV-cache shift on a standard
  quantized cache (q8_0/q4_0) dereferenced a null tensor in the rope-shift path and
  crashed the engine. Fixed in both engines (patches 0001 and 0002).

### Added
- **Prompt cache reuse** toggle (Settings) — reuses the cache across mid-prompt edits
  (coding assistants) and trimmed reasoning instead of reprocessing. Fast but
  approximate; turn it off for exact, reproducible results.
- **Styled, pinnable tooltips** — the ⓘ next to each setting opens a formatted
  explanation on a short hover, and a click keeps it open.

### Changed
- **Settings are now self-consistent** — incompatible options disable or hide each
  other (turbo KV types hide while cache reuse is on; Flash Attention follows the AMD
  kernel; disk cache requires the AMD kernel).
- **AMD Flash Attention kernel now covers all standard KV combinations** (experimental
  engine): f16/q8_0/q4_0 in any keys/values mix run on the GPU — so you can compress the
  keys while keeping values at full precision (q8_0/f16) without falling back to the CPU.
  Tooltips and docs updated; kernel head-dim coverage noted as 128/256/512 (Gemma 4).

## [0.81.23] - 2026-06-17

### Added
- **Remember conversations (disk cache)** — optional, on the experimental engine
  (Settings). Persists each chat's KV cache, so reopening it or restarting the app
  skips re-processing the prompt. Reload is byte-exact and verified faithful (same
  output, even with sampling); on a long chat it reloads in well under a second
  instead of re-prefilling.
- **Faster cold start for external clients** (VS Code / Cline): the engine now
  pre-warms its cache across restarts, so the first request skips the multi-minute
  prefill of the big fixed prompt (experimental engine, non-MTP models).
- **Split model across all GPUs** (experimental) — splits the model's layers over
  every detected GPU instead of one, for machines with multiple cards. Shows a
  visible warning: it's unvalidated on AMD/Metal and needs testing.

### Changed
- Unit tests now run locally via `./scripts/test.sh` (points at Xcode for XCTest).

## [0.81.22] - 2026-06-17

### Changed
- **Default language is now English.** A fresh install starts in English; your
  choice in Settings is remembered and always wins.

## [0.81.21] - 2026-06-16

### Fixed
- **Gemma 4 no longer runs its attention on the CPU.** Its global-attention
  layers use head dim 512, which the AMD Flash-Attention kernel didn't cover, so
  they fell back to the CPU during prompt processing. The kernel now handles head
  dim 512 (NSG=8) and auto-enables for these models on the experimental engine.
  - With quantized KV (q8_0) the global layers go ~8 → ~36 tokens/s (≈4× over the
    CPU fallback); output verified coherent.
  - No regression on existing models (4B/8B head 128, 9B coder head 256 unchanged).

## [0.81.20] - 2026-06-16

### Added
- **Context up to 256k tokens** in Settings (for testing), with a warning when
  it's very large; chat response-token options raised to match.

### Changed
- **Download progress is visible on the card** — a live bar with %, MB and
  pause/cancel, right where you press Download.

### Fixed
- **"Reasoning off" now also sends `/no_think`**, so more models actually stop
  thinking (some reasoning-only models still can't be turned off).
- Build error in the test suite (it used the renamed recommendation API).

## [0.81.19] - 2026-06-16

### Added
- **Logs tab** — full-height server log with search, severity filter
  (all/warnings/errors), follow toggle, copy and diagnostics export.
- **More recommended models** — picks per use case: fastest, everyday (8–9B),
  top quality and coding.
- **Live "Trending on Hugging Face"** list in the Models tab.

### Changed
- **Models tab redesigned** — cards instead of a dense list, split into
  Recommended / Browse / My models.
- **Recommendations are hardware-aware** — chosen from the AMD VRAM tiers real
  Intel Macs and Hackintoshes use.
- **Catalog refreshed** — added Llama-3.1-8B, GLM-4-9B and Gemma-4 (12B and the
  26B-A4B MoE).

### Fixed
- **Long answers no longer slow down or stall generation.** The chat reader was
  decoupled from rendering, so a slow frame can't backpressure the engine; the
  streamed text is now drawn incrementally instead of fully re-parsed each token.

## [0.81.18] - 2026-06-16

### Fixed
- **Chat could drop the connection ("cancelled after ~30s") while waiting for
  the first token on a long prompt.** The streaming request ran on
  `URLSession.shared`, whose ~60-second idle timeout effectively overrode the
  per-request value, so the connection was cut when the first token took longer
  than that (e.g. a long prompt re-processing). Streaming now uses a dedicated
  session with a 10-minute idle timeout, so a slow first token no longer drops
  the chat. Confirmed the server was never the cause — it held a 168-second
  request to completion in testing.

## [0.81.17] - 2026-06-16

### Fixed
- **The experimental engine took ~45 s to load a model and often "started only
  after several tries."** The bundled engines compiled their Metal shaders from
  source on every launch; with the larger AMD Flash Attention kernel set that
  runtime compile ballooned to tens of seconds, so the app looked stuck and
  needed retries. The engines now ship a precompiled Metal library and load it
  directly — model load drops to ~2 s. The shader source stays embedded as a
  fallback: GPUs whose feature set doesn't match the precompiled library (M5-class
  tensor GPUs, or any case where it can't load — e.g. an older macOS) transparently
  compile from source, so nothing breaks and there's nothing extra to install.

## [0.81.16] - 2026-06-16

### Changed
- **AMD Flash Attention kernel is much faster at depth.** Each threadgroup now
  splits the KV stream across more simdgroups (32 for head dim 128, 16 for head
  dim 256), turning the long serial decode loop into shorter parallel ones. On
  the reference RX 6700 XT with a turbo KV cache: generation at 4096 tokens of
  context goes from 19 → 33 t/s on an 8B (+75%) and 26 → 31 t/s on a 9B coder
  model (+17%); at 2048 tokens, +42% and +11%. Output is bit-for-bit unchanged
  (validated on both head dims); prompt processing is within ~3%. The kernel also
  skips fully-masked positions before the score computation, trimming wasted work
  in long-prompt prefill.

### Fixed
- **Chat generation no longer stalls on long conversations.** While streaming, the
  whole Markdown transcript was re-laid-out on every token; on a discrete AMD GPU
  (shared between the UI and Metal inference) those layout passes starved the
  inference and froze generation for several seconds at a time. Completed Markdown
  blocks are now frozen (only the block being written re-renders), and the
  auto-follow scroll is throttled so it no longer measures the entire transcript on
  every token. Generation stays smooth on long chats.

## [0.81.15] - 2026-06-15

### Added
- **AMD Flash Attention kernel now runs prompt processing on the GPU too**, not
  just generation. For quantized/turbo KV (which forces Flash Attention) the CPU
  fallback collapses with depth — e.g. turbo prefill at 2k tokens ~6 t/s — while
  the GPU kernel stays flat at ~100 t/s (q8 2.5×, turbo 16× faster at 2k).
  Validated with needle-in-haystack retrieval over long contexts. This removes
  the multi-minute prompt-processing stalls on long conversations.

### Fixed
- **Crash with the AMD kernel + quantized KV cache.** `--cache-reuse` shifts KV
  chunks when a prompt diverges mid-way (e.g. on auto-compact); the kernel reads
  the quantized cache directly and did not account for that shift, segfaulting on
  the next attention op. Cache reuse is now disabled while the AMD kernel is active.
- **Chat could time out on long prompts.** The streaming idle timeout was raised
  to 3 minutes as a safety net (largely moot now that prompt processing runs on GPU).
- **Slow/laggy chat rendering on long answers.** The Markdown re-render now flushes
  adaptively (less often as the answer grows) so it keeps pace with generation.

## [0.81.14] - 2026-06-15

### Added
- **AMD Flash Attention decode kernel** (experimental). A from-scratch Metal kernel
  that runs generation-time attention on discrete AMD GPUs, exposed as a toggle on
  the experimental engine (Settings → Inference engine → Experimental → "AMD Flash
  Attention kernel"). Supports head dims 128 and 256 and KV types f16, q8_0, q4_0
  and turbo2/3/4 (including the asymmetric pairs the TurboQuant engine allows).
  Quantized and `turbo*` KV caches require Flash Attention, which otherwise falls
  back to the CPU on AMD; the kernel keeps it on the GPU (measured ~14 → ~31 t/s
  for turbo KV at 1k context). Prompt processing still runs on the CPU. Off by
  default; the standard engine is unchanged. See the README research note.

### Fixed
- **MTP crash on AMD.** Speculative decoding (`draft-mtp`) could abort mid-generation
  with `GGML_ASSERT(buf_dst)` in the Metal backend: the draft path reads hidden-state
  embeddings back from the GPU through an asynchronous transfer that the AMD staging
  patch did not yet cover. The staging fallback now also wraps that async read path.

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
