# Changelog

All notable changes to ToshLLM are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/).

## [0.85.9] - 2026-08-26

### Added

- **Audio is now a full workspace beside Chat, Images and Video.** Whisper.cpp transcribes microphone, audio and video on the Radeon; projects preserve editable original and translated tracks, synchronized playback, calibrated Silero VAD, recovery, subtitle exports and captioned MOV copies. Feature requested by [playexit](https://github.com/engeldlgado/toshllm/issues/73).
- **Audio can translate with Whisper or the loaded chat model.** Chat translation resumes without rerunning Whisper and uses an explicit model, neighboring context, prior terminology and a glossary to keep segments consistent.

### Improved

- **The Italian localization now covers the complete interface.** All current UI strings are translated instead of falling back to English.

### Fixed

- **The server log says what Dynamic MoE actually ran with.** It printed the MoE-on-CPU value you had saved while the cache was running with a different one; it now reports the cache and its slots, and stops passing a CPU-expert count the cache does not use.

## [0.85.8] - 2026-08-24

### Added
- **Dynamic MoE, a private experiment that runs a MoE model on far less video memory** by keeping every expert in system RAM and a small cache of slots on the card. It is off by default and hidden for internal testing; a 35B in Q2_K_XL ran on 2.78 GiB against the 6 GiB its usual setting needs, and generated faster. Read the [what it is and when it pays](https://github.com/engeldlgado/toshllm#dynamic-moe-bounded-vram-expert-cache-private-experiment) section first, especially the RAM it asks for in exchange.

### Improved
- **Models in BF16 read prompts about 30% faster.** 722 → 949 tokens per second on a 4B and 5211 → 6807 on a 0.6B, with generation speed and answers unchanged. Measured on a Radeon RX 6700 XT.

### Fixed
- **A model or projector in BF16 no longer stops the engine on cards that lack BF16.** The load aborted before ever reaching the chat; those weights now run on the card like any other format. Reported by [Slice](https://www.insanelymac.com/forum/profile/112217-slice/).

- **Conversations exported to Markdown are labelled in the language you picked.** The two headings the file writes were always in Spanish. Reported by [guylough](https://github.com/engeldlgado/toshllm/issues/70).

- **Two Duo cards no longer read as four cards.** A Duo puts two GPUs behind one name, so the machine card counted devices and doubled them; it now says two cards and four GPUs. Reported by [chafey](https://github.com/engeldlgado/toshllm/issues/67).

- **The Infinity Fabric Link switch is only offered when there is a link.** It could be turned on with nothing bridged, which read as if the app had found a bridge. Reported by [chafey](https://github.com/engeldlgado/toshllm/issues/67).

- **TurboQuant cache types no longer stop the server when the model is split by tensors.** The split path did not know how to divide the rotation TurboQuant applies to attention, and the engine aborted while loading. Reported by [chafey](https://github.com/engeldlgado/toshllm/issues/69).

## [0.85.7] - 2026-08-22

### Improved
- **Models quantized to about one bit write answers faster.** Their lookup table was read from constant memory four times per row instead of being staged once per group of threads: an 8B in IQ1_S gains 50% more tokens per second and a 9B in IQ1_M 14%, with the output unchanged. Measured on a Radeon RX 6700 XT.

### Added
- **Cache keys at q4_0 can be paired with TurboQuant values.** The combination had no kernel of its own, so it was rejected and attention ran on the processor; it now runs on the card like every other pair.

- **Mistral Small 4 runs its attention on the card.** Its 320-wide keys had no kernel, so every layer's attention fell back to the processor.

- **The reasoning effort list has a "Model default" entry** that leaves the choice to the model instead of sending a level.

- **The machine card counts every GPU and says whether an Infinity Fabric link joins them**, with the memory behind each link and a button for the full breakdown. macOS shows that nowhere.

- **The GPU list marks the linked cards** with a coloured bar, a badge and their device index. The server log names each card's link too.

### Fixed
- **Video memory was rounded down by a whole gigabyte.** A 12 GB card read as 11 GB and a 32 GB one as 31 GB.

- **The reasoning effort list only offers what the model accepts.** Choosing a level its chat template rejects returned an HTTP 500 in the middle of the answer.

- **The TurboQuant warning says which of its reasons applies.** It listed the model, the backend and the type combination in one sentence, and explained only the last.

## [0.85.6] - 2026-08-21

### Added
- **Settings suggests the KV cache types that measure best.** Keys at `q8_0` with Turbo4 values matched f16 quality on 4B, 8B and 35B models while taking a quarter less cache than `q8_0` on both; one click applies it.
- **Each server can bridge MCP for the engine's web interface.** A switch under the server card's advanced options passes `--ui-mcp-proxy`, so the web interface can reach MCP servers on another origin; it is per server, experimental, and meant for trusted networks only.

### Fixed
- **Extra arguments reach router mode too.** Flags typed there were applied to a normal server but dropped when the router served the models.

## [0.85.5] - 2026-08-21

### Fixed
- **Radeon RX 400/500, Radeon Pro 400/500 and Radeon Pro WX no longer write nonsense.** Since 0.84.4 the engine read Q6_K weights four bytes at a time, from addresses those cards need aligned, so half of them came back as neighbouring data. Almost every model keeps part of its layers in that format, the output head among them, which is why whole models turned to gibberish. Reported by [FreQRiDeR](https://github.com/engeldlgado/toshllm/issues/1) and [Slice](https://www.insanelymac.com/forum/profile/112217-slice/).

### Improved
- **Image and video models load about five times quicker.** The loader asked the drive for 4 KiB at a time, so 2.46 GB of weights took 7.8 seconds where the disk does it in 0.7. A cold start of Flux.2 klein 4B drops from 12.9 to 2.5 seconds, with the image unchanged.

## [0.85.4] - 2026-08-21

### Added
- **The Logs tab can now check the engine on your own card.** It runs the engine's operator tests, tells apart the one failure that comes from upstream and is not a problem, and saves the result together with the diagnostics as a single text file you can send. It takes a few minutes and asks for the server to be stopped, since it uses the whole card.

## [0.85.3] - 2026-08-20

### Fixed
- **Separate MTP heads now attach to their base model** ([#60](https://github.com/engeldlgado/toshllm/issues/60)). They stay out of the model menu and work in normal and router modes.
- **Paused model downloads resume reliably after links expire** ([#61](https://github.com/engeldlgado/toshllm/issues/61)). Servers that ignore the requested range restart the transfer instead of corrupting the partial file.
- **Models with 40- or 80-wide attention heads no longer write nonsense.** All 108 affected engine operator tests now pass.
- **The image token cap also limits memory while a vision model loads.** At 512 tokens, a 2B vision model's largest warm-up block drops from 4372 to 228 MiB. Reported by [Slice](https://www.insanelymac.com/forum/profile/112217-slice/).
- **The server log includes environment variables entered in Extra arguments.** Shared diagnostics now show the settings that were actually applied.
- **Video models only offer their supported sizes and frame rates.** Wan 2.1 uses 832×480 at 16 fps; Wan 2.2 uses 1280×704 at 24 fps.
- **Native-size video generation no longer brings down the graphics session.** Wan 2.2 releases 8.5 GB before decoding and keeps long VAE work responsive.
- **Video memory warnings follow the real generation stages.** Wan 2.2 at 1280×704 measured 10.68 GB for 33 frames and 10.97 GB for 49; 49 frames recommend a 16 GB card.
- **Wan 2.1 and Wan 2.2 use their official inference values.** Defaults now follow each checkpoint's steps, CFG, shift, size and frame rate.
- **HunyuanVideo 1.5 downloads its complete conditioning stack.** It now includes the 439 MB ByT5 encoder and uses 50 steps, CFG 6 and shift 7.
- **Negative prompts stay with the matching model family.** Wan, LTX and Hunyuan no longer inherit one another's instructions.
- **Rejected memory blocks now produce the right guidance.** Graph allocations suggest reducing context or image tokens; weight allocations can suggest the buffer cap.
- **Metal shaders precompile reliably from Xcode's downloaded toolchain.** Both bundled engines retain runtime compilation as a fallback.

## [0.85.2] - 2026-08-19

### Fixed
- **Video no longer comes back as a flat colour.** Its attention was built in full instead of going through the card's kernels, and past a certain clip length it stopped fitting in a single allocation. A 33-frame clip at 704x400 is the case that showed it; 832x464 with 33 frames now renders too.
- **Video no longer flickers.** The decode brightened one frame in every four, the rhythm the decoder compresses time at. Decoding in tiles removes it; a setting brings the old decode back.
- **Video no longer ends in colour bands or noise.** Long clips ran past the time macOS allows a single piece of GPU work. The work is now split, and the tiled decode keeps each piece small.
- **Wan 2.2 5B works, and on far less video memory than its listing claimed.** It was being sampled on a schedule that turns its output into coloured mush, worse the more steps it took; on the one it wants it returns a clean picture. It now asks for 12 GB instead of 24, up to 704 pixels, where its decoder still fits.
- **SD 1.5 is no longer offered a frame it cannot render.** That model was trained on square frames only, and any other shape comes back with colour blotches in the background however many steps it takes, so the studio now offers it the square alone and says why. The newer models saw many aspect ratios and keep every framing.
- **Video no longer comes out as a still image.** The studio opened at 480x272, well under what these models were trained at, and there they stop moving: a clip at that size measures 0.5 of change between frames against 20.6 at 704x400. It now opens at the model's own size, and warns if you go below it.

### Improved
- **Images take much less video memory and are made 12 to 14% quicker.** Z-Image at 1600x900 drops from 8.2 GB to 966 MB, and at 1024x1024 from 2.4 GB to 690 MB, with the image unchanged. 2048x2048 and 2560x1440 now render on a 12 GB card.
- **SD 1.5 needs nine times less video memory and is twice as quick**: 281 MB and 73 seconds at 768x768, against 2690 MB and 149. Its head sizes now fit the card's attention kernels, and 1024x1024 works for the first time. This is the model for 4 to 6 GB cards.
- **Video is generated about 32% quicker.** Sampling a 33-frame clip at 704x400 goes from 209 to 142 seconds.
- **The size list follows what the card can really do.** The memory estimate was written when the attention was built in full, and hid sizes that now fit.
- **Models no longer ask for twice the card they need.** The stated minimums were set when the attention was built in full: Z-Image and SDXL Turbo drop from 8 to 6 GB, Flux.2 klein 4B from 12 to 6, klein 9B from 16 to 10, Flux.1 schnell from 16 to 8, Qwen-Image from 24 to 16, and the large video models from 32 to 24. Measured where the model is here, derived from the same figures elsewhere.
- **Each studio says what its model was trained for**, so a repeated composition or a drifting clip reads as the model's limit and not as the app's.
- **Updated image engine**, with the fixes released upstream since the last version.

Measured on a Radeon RX 6700 XT with Wan 2.1 1.3B, Z-Image Turbo, SDXL Turbo and SD 1.5.

## [0.85.1] - 2026-08-19

### Added
- **A working directory per conversation and per project.** With agent tools on, the model's file tools stay inside the folder you pick, shown next to the conversation's title.
- **A cap on how many tokens an image may take.** The model's limit is kept by default; lowering it in Settings is what lets a vision model load on an 8 GB card. Reported by [Slice](https://www.insanelymac.com/forum/profile/112217-slice/).
- **Time to first token** in each answer's metrics.

### Fixed
- **File tools are no longer offered when the chat has no working directory**, so the model stops trying to edit files that do not exist.
- **Router mode no longer fills video memory with models that use older attention.** Llama 2 and similar asked for 8 GB of key-value cache at 16k context, enough to freeze the machine; each model now gets a context that fits.
- **Stopping the server no longer leaves a model in memory** in router mode.

### Improved
- **Updated inference engine**, with the fixes and new model support released upstream since the last version.
- **New web chat in the browser**: the llama.cpp interface, rebranded for ToshLLM, with a model picker that works in router mode. Requested by [urfin78](https://github.com/engeldlgado/toshllm/issues/59).
- **Memory estimates read each model's real attention layout.** On a 7B with older attention at 16k context the old guess was 0.8 GB against a real 8 GB.
- **The speculative decoding readout follows the answer as it is written.**

## [0.85.0] - 2026-08-17

### Fixed
- **Gemma 4 no longer stops the engine when part of it runs on the processor.** When the model did not fit entirely in video memory and the key-value cache was quantised, any prompt past about forty tokens ended in a fatal error. Reported by [Slice](https://www.insanelymac.com/forum/profile/112217-slice/).

### Improved
- **Serving two or three conversations at once is 25 to 34% faster.** On a 9B at Q5_K_M, two go from 56.4 to 70.8 tokens/s and three from 60.5 to 81.0. A single conversation and four or more are unchanged.
- **Follow-up questions in a conversation already in cache are read faster.** The gain is over the nine or ten tokens a short question adds to a conversation, on models at Q4_K, Q3_K and Q2_K. Other formats and longer prompts are unchanged.
- **Smaller quantisations are considerably faster.** A 1.5B at IQ2_M writes answers 49% faster, from 92.1 to 140.8 tokens/s; a 7B at IQ3_XXS reads prompts 7% faster; and models with q5_0 or q5_1 weights about 15% faster. Perplexity is unchanged throughout.
- **DeepSeek and GLM models read long prompts up to 31% faster.** A 23B GLM goes from 203.8 to 257.5 tokens/s with 4096 tokens already in context, and from 121.5 to 159.2 with 8192.
- **The experimental turbo key-value cache is no longer the slowest option.** At 4096 tokens of context turbo3 goes from 55.8 to 59.8 tokens/s and turbo4 from 56.8 to 60.5, against 58.1 for q8_0. Perplexity is unchanged.

#### Radeon Vega, Radeon VII, RX 400/500 and Radeon Pro Vega/WX

These cards were tuned with settings measured on the newer Radeons, and most of them wanted different ones.

- **Models write answers 4 to 24% faster.** A 9B at Q5_K_M goes from 31.2 to 38.8 tokens/s, an 8B at Q6_K from 35.5 to 41.4, a 4B at Q2_K from 49.9 to 58.0 and a 7B at IQ3_XXS from 42.2 to 44.4. Mixture-of-experts models gain too: a 7B with 64 experts goes from 136.0 to 155.3. Perplexity is identical.
- **Serving several conversations at once is 9 to 12% faster, and multi-token prediction gains 8%.** On a Radeon RX Vega 64, a 4B goes from 108.3 to 121.1 tokens/s with four conversations and from 119.5 to 133.6 with eight; a 9B at Q5_K_M from 47.4 to 51.6 with four.
- **Prompts are read faster at every length.** A short follow-up question gains up to 39%, prompts of 130 to 160 tokens 2 to 4%, and long prompts 3 to 5%: llama-2-7B goes from 509 to 528 tokens/s at 512 tokens and a 1B at IQ4_XS from 2811 to 2941. Perplexity is identical.
- **Mixture-of-experts models can now use the faster path the newer Radeons already had**, which had been locked to those cards without ever being measured on these. On gpt-oss-20b it reads prompts up to 23% faster at twelve of fifteen lengths, but loses about 17% around 470 tokens, so it is not on by default: enable it with `TOSH_MMID_WIDE_W64_ENABLE=1`.

Measured on a Radeon RX 6700 XT, and on a Radeon RX Vega 64 for the section above.

## [0.84.4] - 2026-08-15

### Fixed
- **A model that does not fit no longer crashes the engine.** When the card refused a memory block the engine read the failed allocation anyway and died with a segmentation fault instead of reporting the problem, so the app could only say the engine had stopped. The failure is now reported, and the message tells you what to do about it. Diagnosed by [Slice](https://www.insanelymac.com/forum/profile/112217-slice/) on an RX 570, who also traced it to the exact line.
- **A card that refuses one large block can now split it.** Some drivers advertise room for a 4 GiB block and then turn it down; starting with `TOSH_METAL_MAX_BUFFER_MB=1024` splits the weights into smaller blocks instead, at the same speed. Also suggested by Slice.

### Improved
- **Mixture-of-experts models read prompts up to 18% faster.** The wider matrix tile that dense models already used now also serves the expert matmul, and an expert that receives few tokens skips the columns it would only pad. gpt-oss-20b goes from 1093 to 1292 tokens/s on a 512-token prompt, and a 14B A3B from 1235 to 1315.
- **Qwen3.5 and Qwen3.6 models write answers 7 to 14% faster.** Most of their layers copy a running state once per token, and that copy went through a kernel that rebuilds a four dimensional index for every single number it moves. A copy whose two sides are already laid out in order now skips all of that: 62.2 to 70.8 tokens/s on a 14B A3B and 43.0 to 46.2 on a dense 9B.
- **Speculative decoding carries the gain too.** On a Qwen3.5 4B writing code, MTP goes from 70.0 to 81.6 tokens/s and DFlash from 68.9 to 82.6; on mixed unpredictable text, MTP from 63.7 to 73.8 and DFlash from 60.7 to 68.3. The draft acceptance rate is identical down to the last counter in every pair, so the speedup is the kernels and not a different acceptance pattern.
- **Q4_K models are faster at both ends.** The scales of a block took five separate small reads; the sixteen bytes they live in are one aligned read, and the block layout already guaranteed it. Reading a prompt gains 1.8 to 2.6% and writing an answer 1.1 to 1.5%, measured on a dense 8B and on Gemma 4 E2B.
- **Q6_K tensors are read a word at a time.** That quantisation was the only one still read a byte at a time, because its block size left the compiler unable to assume anything about alignment. Its matrix-vector step drops about 20%.

Measured on a Radeon RX 6700 XT against 0.84.3. Models without any of these traits, such as Llama 2, are unchanged.

## [0.84.3] - 2026-08-14

### Improved
- **Prompts are read 5 to 7% faster.** The prefill matrix kernel stalled on shared memory more often than it needed to; widening one of its two reads cuts those stalls by two thirds, and the faster kernel now also pays off on shorter prompts, so it starts being used from 112 tokens instead of 192. Measured on llama-2-7B: 799 to 859 tokens/s at 128, 868 to 933 at 190, 944 to 990 at 512.
- **Mixture-of-experts models read prompts about 2.7% faster.** Their matrix kernel converted its running totals four times more often than the one dense models use; it now does it once, like the other.
- **Mixture-of-experts models kept in video memory also answer about 1.5% faster.** The engine reordered their graph while writing, which disturbs the expert lookup for no gain on AMD; it no longer does.
- **Models quantised as Q5_K answer a little faster.** Their fifth-bit path took six narrow memory loads per step and now takes three wide ones, reaching the throughput the other quantisations already had.

## [0.84.2] - 2026-08-14

### Fixed
- **A conversation with code blocks no longer freezes while you scroll it** ([#58](https://github.com/engeldlgado/toshllm/issues/58))... every code block, and every panel of a tool call, carried a scroll view of its own, and each one re-tiled on every geometry change while scrolling. On macOS 15 that could leave the app unresponsive for half a minute. Long lines now wrap to the bubble and the expand button still opens the full-width view.
- **Quitting the app always stops the engine.** With the prompt cache enabled the engine was told to stop only after the app had finished saving its cached prefix, and that save could not finish once the app was on its way out, so the engine stayed running and holding video memory until you noticed it. The prefix is still saved on the way out, now with a time limit that the shutdown never waits past.

### Improved
- **The window no longer stalls for a few seconds on launch.** The model menu was reading the header of every model in the folder while it drew, which on a folder of large models meant a spinning cursor before the app was usable. The headers are now read in the background and the menu fills in as they arrive.
- **Scrolling away from an answer while it is being written no longer rebuilds it.** The typewriter and the plain view were two separate branches, so stepping away threw the formatted text away and built it again from scratch.

## [0.84.1] - 2026-08-14

### Fixed
- **An upscaled image is saved next to the original**, instead of landing in the models folder. Upscaling a photo from anywhere on the disk left the result among the model weights, and upscaling a generated image produced a file the "delete images on app close" option then wiped. The name also states the size you asked for, ×2 or ×4, rather than always ×4, and an existing file is never overwritten.
- **Scrolling the chat no longer gets stuck on an answer about code** ([#58](https://github.com/engeldlgado/toshllm/issues/58))... a paragraph mentioning two shell variables, or two prices, was read as a formula and handed to the formula renderer, which turned the text into unreadable maths and swallowed the mouse wheel. Only what really looks like a formula is treated as one now, and a formula or diagram in the middle of a conversation passes the wheel through to the chat.
- **Engine errors are shown in your language.** Every diagnostic the engine produces was being printed with the Spanish and the English text one after the other, separated by a slash, in the same line. There are thirty of these messages and all of them read that way.
- **A failed engine no longer spills its whole explanation across the toolbar.** The state now shows a warning triangle and the word Error, with the full diagnosis when you hover it.
- **The menu bar icon tells a crashed engine from a stopped one.** They looked identical, which mattered because a crash is the one thing worth noticing while you are working in another app. Starting has its own icon too, and the icon now announces its state to VoiceOver.
- **The video studio says it is preparing the frames** instead of looking as if nothing had been generated during the moment between the run finishing and the frames being ready.

### Improved
- **Scrolling back through long code answers is smoother.** The syntax colouring of a code block was recomputed every time the block came back into view; it is now kept.
- **Video generation needs 6.7 GB less video memory, and image generation 1.6 GB less.** The text encoder was staying on the card for the whole run after finishing its work in the first seconds; it now waits in system memory. On a 12 GB card this is the difference between 480p and larger formats.
- **Images and video are generated 2 to 3% quicker**, using a matmul shape better suited to them than the one tuned for reading prompts. The result is identical.
- **The upscaler asks before it starts.** Choosing files now queues them, with a separate button to run, and every finished image of a batch stays one click away under the comparison.
- **Buttons that show only an icon tell a screen reader what they do**, and the upscale comparison can be moved with the keyboard rather than only by dragging.
- **The chat text size is in the View menu**, so the shortcuts are visible and work everywhere in the app instead of only inside the chat.
- **The memory estimate accounts for splitting by tensors**, which reserves a working buffer per card and per reduction step.

## [0.84.0] - 2026-08-13

### Added
- **Video generation, and it is experimental.** Treat this as a first cut, not a finished feature: a third mode next to Chat and Images turns a description into a short clip, with Wan 2.1, Wan 2.2, LTX-2 and HunyuanVideo in the model list and the download sizes stated before you commit to one. The result arrives as individual frames you can scrub through, and exports to mp4. What to expect before you try it: a few seconds of video take minutes, a clip of 49 frames at 480p already fills a 12 GB card, and only the smallest model (Wan 2.1 1.3B) fits one at all. The rest ask for 24 GB or more. Longer clips and higher resolutions fail rather than degrade, and the frame count has to be one of the values offered. Expect the settings and the defaults to move in the next releases.
- **An image upscaler that also takes your own photos.** Images now has Create and Upscale tabs; Upscale enlarges anything you pick, several files at a time, and shows the before and after under a slider you drag to compare. Three models: one trained on real photographic damage, one for generated art, and your own file if you have a favourite.
- **The image being generated is now visible while it is generated**, refreshed every few steps, instead of a progress bar and a wait.
- **The benchmark history records whether Infinity Fabric Link was on**, so a shared result can be told apart from one measured with the bridge off.

### Fixed
- **Video no longer comes out as noise on AMD cards.** The 3D convolution the video decoder needs had no Metal implementation, so it fell back to a version slow enough that the card gave up mid-frame and returned whatever was in memory. Decoding a clip went from about three minutes to nineteen seconds in the process.
- **Infinity Fabric Link says when it will do nothing.** Turning it on while splitting by layers has no effect, because the transfer it accelerates only happens when splitting by tensors; the setting now says so instead of looking active.
- **The memory estimate accounts for splitting by tensors**, which reserves a working buffer per card and per reduction step that was not being counted.

### Improved
- **The chat redraws less while an answer streams in**, and file edits in tool results no longer re-split their text on every token.

## [0.83.23] - 2026-08-13

### Fixed
- **The engine starts again on macOS 15 and earlier**... the released binaries are built on the newest macOS and were tied to it, so once the engine update in 0.83.22 began calling a routine that only exists there, the engine quit at launch on every older system. It is now built for the same macOS the app itself asks for, and packaging refuses a binary that is not.

## [0.83.22] - 2026-08-13

### Added
- **More model families run**... the engine update brings MiniMax-M3, GLM-5.2 with vision, Granite-Switch, Nanbeige and Muse Glimmer, and multi-token prediction now works on Nemotron, Qwen3-Next, GLM-4.7-Flash and DeepSeek V3.2.
- **Models built around a Hadamard transform run on GCN and Vega cards too**... the transform assumes lanes come in groups of 32, and those cards group them in 64.
- **Every conversation can be deleted at once**, from the chat settings or the menu next to the chat search box. Projects and their prompts are kept.
- **The installer window is a designed one.** Opening the DMG now shows the app and the Applications folder on subtle glass landing zones over an obsidian hardware composition in the app's colours, with an arrow between them, and the disk carries the app's icon. The layout ships as a saved window arrangement, so the release built by CI looks the same as one built by hand.
- **The chat text has its own size**, with ⌘+ and ⌘− while chatting, ⌘0 to go back, and a slider in the chat settings. It grows the messages and the input field from 80% to 200%, and leaves the rest of the interface where it is.
- **The interface answers to the accessibility settings of the system.** Buttons that show only an icon now tell a screen reader what they do, and the translucent surfaces turn solid when "Reduce transparency" or "Increase contrast" is on.

### Fixed
- **Mixture-of-experts models no longer crash when split between card and processor**... a step handing more than thirty inputs to the next one overflowed a fixed-size list, which is reachable on Gemma 4, Qwen and DeepSeek.
- **Memory is given back when a model is unloaded**... serving several models from one process kept the previous model's memory reserved if that model had never run anything on the card.
- **Some layer widths no longer normalise to the wrong value**... a row whose length left a partial group of lanes dropped part of its sum, so the average and variance for that row came out wrong.
- **The benchmark loads the model the way the server does**... it ignored the memory options and always loaded unlocked, so it was not measuring the configuration it reported, and the shared result recorded a fixed value instead of the real one.
- **Locking the model in RAM no longer switches off memory mapping behind your back**... the updated engine folds both options into a single setting where the last one given wins, so on the Macs that keep mapping on, turning the lock on silently disabled it.
- **Answers no longer stall in clients that reuse a conversation**... reading a prompt very similar to the previous one could count the reused tokens wrong when a draft model was in play.

### Improved
- **Predictable answers arrive 3 to 5% faster**... the draft head gave up whenever acceptance fell below a bar that sat above what real content reaches, on every card and not only the older ones.
- **Prompts are read 3 to 5% faster on GCN and Vega cards**... the wide matmul tile was measured on RDNA 2 and loses on the older ones from 256 tokens up, so they keep the narrow one.
- **Serving several models chooses better which one to unload**... it now drops the least recently used instead of an arbitrary one, and never a model that is answering.
- **Both engines move to current upstream**... the language engine had drifted 329 commits behind and the image engine four releases of its shared core, which also carries the security updates of the bundled web stack. Prompt and generation speed measure identical on dense and mixture-of-experts models.

## [0.83.21] - 2026-08-12

### Improved
- **Prompts are read 2 to 3% faster on dense models.** The matmul cleared its 32 running totals before every pass over the weights; the first product of each pass now writes into the total instead, leaving nothing to clear. llama-2-7B Q4_0 goes from 919 to 949 tokens per second and Qwen3-8B Q4_K_M from 785 to 803, with identical output. Mixture-of-experts models gain about half a percent.

## [0.83.20] - 2026-08-12

### Fixed
- **Logs now say which card each GPU slot is, and which architecture the engine was built for.** macOS renumbers the GPUs on every reboot, so a slot number on its own did not identify the card a log came from, and on a machine with several cards there was no way to tell afterwards which ones a run had used. Each startup line now carries the device name and its peer group. The version line also reported the architecture of the machine that built the engine rather than the one it runs on, so a release built on Apple Silicon described its Intel binary as arm64.

### Improved
- **Short prompts whose length does not divide evenly are read up to 18% faster.** The matmul reads tokens 64 at a time, so a prompt ending 32 or fewer past a multiple of 64 paid for a half-empty group: 96 tokens took as long as 128. Those sizes now use the 32-token tile, which covers them exactly. At 96 tokens the gain is 10% on Q4_K, 12% on Q6_K and Q8_0 and 18% on Q4_0, and a 67-token chat request reads its prompt 13% faster. Ten weight formats were measured and all of them gain, except the 1 and 2-bit IQ formats past 128 tokens, where the narrower tile costs more in repeated dequantization than the padding it saves, so those keep the old one there. Sizes that already divided evenly, and prompts of 512 tokens or more, are untouched and measure identical.

## [0.83.19] - 2026-08-12

### Faster
- **Prompt processing is faster on eight more weight formats.** The wide matmul tile only ran on nine of them, so common quants like Q4_0 and the IQ family fell back to the narrow one. llama-2-7B Q4_0 goes from 878 to 915 t/s (+4.2%) and Qwen3-8B Q6_K from 742 to 764 (+2.9%), with identical perplexity. Narrow matrices keep the old tile, which measured faster for them.

### Fixed
- **Stopping an answer no longer breaks the rest of the conversation in external clients**... interrupting a reply mid-stream left the client holding a turn the server then refused, so every later message in that conversation came back as an error until the history was deleted by hand. A finished turn carries a marker that an interrupted one never gets, and the server was treating that marker as required even though it is optional.

## [0.83.18] - 2026-08-10

### Improved
- **Reading a short prompt is up to 9% faster**... the wide matmul tile splits a work group into half as many pieces, so it only pays off once there are enough tokens to keep the GPU busy, and it was being used at every size: prompts of 64 tokens lost 9% to it on 8-bit and 5-bit models. It now waits for 192 tokens, and 4-bit K-quant models, the most common kind, join it above that size for 2% more on long prompts. Perplexity is unchanged.

## [0.83.17] - 2026-08-10

### Added
- **Multi-GPU can now split each layer between the cards instead of handing them out whole**... splitting by tensors puts both GPUs on the same token, so prompts are read far faster and, on a model of tens of GB, generation is faster too: a 27B on a dual card went from 281 to 377 prompt tokens per second and from 8.1 to 11.6 generated. Pick it in Settings, next to the fast hand-off it needs, which is on by default whenever a model is split. Splitting by layers stays the default and is still the faster of the two on models that fit comfortably.

### Improved
- **Splitting by tensors generates 26% faster, and now covers more than two GPUs**... each hand-off between cards opened one command buffer to carry the data and a second one to add it in, and creating them cost as much as the copy itself, so the addition now goes into the buffer the copy already opened. Three or more cards were also falling back to a generic reduction that submits a whole graph per addition, and now use the same fast path as two: 24% more generation on three devices and 12% on four. Output is identical token for token.
- **Each transfer between cards is picked for what it is doing**... the Infinity Fabric copy is ahead when reading a prompt and the event hand-off when generating, and they were tried in a fixed order that gave up a fifth of the generation speed. The engine now chooses per batch.

## [0.83.16] - 2026-08-06

### Improved
- **Scrolling up during a long answer now holds the text still**... the chat followed the stream to the last word written, so reading a long reply while it was being written meant chasing moving text. Scrolling far enough that the answer's last lines leave the view now freezes it where you left it and generation carries on off screen; nearer than that it keeps following, so a small scroll never looks like a stall. The floating button, tinted while there is more waiting, takes you back to the end and resumes following, and so does scrolling there yourself; coming back lands on the text as it stands, instead of typing out everything that piled up at several times the real speed. Only a scroll of your own changes any of this, so a turn finishing never moves the view.
- **Scrolling back through a long conversation no longer stutters**... every message that left the view was formatted again from scratch on the way back, and formatting a single paragraph costs about 0.13 ms: four messages arriving in the same frame spent 7 ms of the 16 a frame has, which is where the catching came from. Formatted paragraphs are now kept around, and those same four cost 0.012 ms.

### Fixed
- **The button that jumps to the end of a conversation no longer misses clicks**... only the arrow itself took the press, so anything landing on the rest of the circle did nothing.

## [0.83.15] - 2026-08-06

### Added
- **Downloaded models say when their repo has re-published the file**... the app already remembered where each model came from, and now compares it against the checksum Hugging Face publishes for that file: My models flags the difference and offers to download it again, replacing the local file only once the new one verifies.
- **Model cards and model menus show what each GGUF brings**... experts, vision projector, multi-token prediction head and DFlash draft are now visible where you pick a model, instead of only where each one is configured.

### Improved
- **Models and Logs look and behave the same everywhere**... one button and segmented-control identity, tinted with the accent picked in Settings, uniform model cards, and proper empty states.
- **Better filters**... My models filters by vision, MTP, DFlash or experts, and the Hugging Face browser sorts by trending, downloads, likes or last updated.
- **Browsing and the model grid are quicker**... badges and download checks no longer hit the disk on every redraw, and long file lists render as you scroll.

## [0.83.14] - 2026-08-06

### Improved
- **Speculative decoding stops running a whole draft block whose output nobody reads**... after each accepted token the draft head was re-run end to end to keep its cache in step, including the attention, feed-forward and output stages, when only the cached keys and values are ever used again: that pass now ends once they are written, going from 50 graph nodes to 20, with byte-identical output. A 4B model gained 0.6% on the content where speculation struggles, which is where those catch-up passes are most frequent, and 0.4% where it already works well. Mixture-of-experts models measured unchanged, the saving diluted by a token that costs twice as much.
- **Two-GPU tensor split now picks the faster transfer for each kind of hand-off**... the event-based transfer and the Infinity Fabric peer copy were tried in a fixed order, so enabling both meant the peer copy always won even where it is slower. Tensor split now prefers events, measured 24% faster in generation on a dual Vega II, while the per-layer hand-off keeps preferring the peer copy, which is the one ahead on prompt processing.

## [0.83.13] - 2026-08-05

### Improved
- **Speculative decoding costs much less on the content where it does not help**... while acceptance stays low the engine disengages, but it kept the draft cache in step one decode per token and only disengaged below 50% acceptance, under the 54% break-even measured on this hardware: those catch-ups are now replayed in a single batch before the next attempt, and a 4B model on technical prose went from 58.5 to 60.5 t/s against 64.6 without speculation. Predictable content, where it does help, is unchanged at 91.4 t/s against the same 64.6.
- **Speculative decoding no longer writes rollback state a model cannot use**... models with recurrent layers save one state checkpoint per token the draft may need to undo, and saved the full set on every pass, including the single-token ones where nothing can be undone: those passes now write 48 state copies instead of 96 and generation gained 1.3%, with identical output and identical acceptance.

### Fixed
- **The automatic parameter fit no longer reports `abort` with `--split-mode tensor`**... it is not implemented for that mode, so the model always loaded normally with the parameters as given, but the wording read like a fatal error.
- **The GCN/Vega startup line no longer under-reports which formats decode on the GPU**... it named six quantization types while the engine covers twenty, Q4_0 among them, which made benchmark reports look like they had fallen back to the CPU.

## [0.83.12] - 2026-08-05

### Fixed
- **Tensor-split peer transfers no longer allow the sending GPU to overwrite data still being read**... the receiving queue now signals completion back to the sender before that source can be reused. The two-queue regression that produced corrupted text in three out of three runs now matches the generic transfer path byte for byte.

### Improved
- **Tensor split now uses Metal's native two-GPU all-reduce when the tensors are compatible**... eligible reductions copy into reusable private scratch buffers and encode the addition directly instead of submitting a one-node graph per GPU. It handled all 9,360 reductions in a 128-token validation run, while unsupported shapes keep the existing fallback.

## [0.83.11] - 2026-08-04

### Improved
- **Models load four times faster with `--split-mode tensor`**... each split tensor was uploaded one row at a time, and every row paid for its own command buffer and its own wait: Qwen3 8B went from 12.6 to 3.0 seconds, which is what the same model takes on a single GPU.
- **Generation is faster with `--split-mode tensor`**... the ~150 graphs submitted per token each created, dispatched and committed extra command buffers that had nothing left to encode: Qwen3 4B went from 33.7 to 39.0 t/s, with identical perplexity.

## [0.83.10] - 2026-08-03

### Fixed
- **Models with very large activations no longer produce garbage on AMD GPUs when Flash Attention is off**... the tiled matrix multiplication accumulated attention products in half precision, which overflowed to infinity and left the softmax as NaN: Qwen2.5 1.5B answered `@@@@@` and now answers normally.

### Improved
- **Long prompts are much faster on GCN/Vega**... attention during prompt processing was decomposed into separate matrix multiplications there, because the blocked Flash Attention kernel had only been validated on 32-lane GPUs: on a Radeon RX Vega 64, Qwen3 4B went from 295 to 457 t/s at 8k of context, and Llama 3.2 1B from 917 to 1553 t/s, with identical perplexity.
- **More operations run on the GPU on GCN/Vega**... sums, argmax, count-equal and the SSM scan were gated on a 32-lane reduction and fell back to the CPU: they now size their reductions and shared memory by the detected 64-lane width. Argmax matters for speculative decoding, and the SSM scan for Mamba-style models.
- **Ternary Q1_0 and Q2_0 models generate on the GPU there too** ([#41](https://github.com/engeldlgado/toshllm/issues/41))... they loaded and processed prompts on the GPU but decoded on the CPU, because their matrix-vector kernels split work across a fixed 32 lanes.
- **Fused Q/K/V decode covers Q2_K on GCN/Vega**... the specialization was held back to 32-lane GPUs while its matrix-vector kernel was ported, which finished in 0.83.9.
- **Qwen3-VL, Qwen3.5 and Qwen3.6 models now reuse the prompt cache and can shift context** ([#52](https://github.com/engeldlgado/toshllm/issues/52))... the engine refused every cache shift on these models, so editing the beginning of a prompt reprocessed all of it: an 821-token prompt whose opening note was deleted is now reused whole instead of processed again.
- **BF16 models and vision towers are faster on AMD GPUs**... their matrix multiplications now accumulate in float instead of emulated bfloat: prompt processing measured 77% faster on Qwen3 0.6B BF16, and a BF16 vision encoder went from 8.6 to 7.6 seconds per image on a Radeon RX Vega 64.

## [0.83.9] - 2026-08-02

### Improved
- **Q2_K, Q3_K and IQ models now generate on the GPU on GCN/Vega**... their matrix-vector kernels read the detected 64-lane SIMD width instead of a hard-coded 32, so generation no longer falls back to the CPU: Qwen3 4B Q3_K_M went from 3.96 to 44.04 t/s on a Radeon RX Vega 64 (8 GB).
- **MXFP4 models, including gpt-oss, decode on the GPU there too**... the same width fix plus a value table sized by the real width, measured 18.2 t/s generation and 191 t/s prompt processing on gpt-oss 20B with the experts of 16 layers kept on the CPU, also on a Radeon RX Vega 64 (8 GB).

## [0.83.8] - 2026-08-01

### Added
- **TurboQuant KV cache is back in the bundled engine**... Turbo3 and Turbo4 now work without the retired experimental binary, including cooperative GPU writes, cache reuse and context shifts. The AMD attention path covers regular and padded head sizes from 128 through 640 on both wave32 and wave64 GPUs. Turbo4 is recommended from 4B models upward; Turbo3 trades more quality for memory and is intended for larger models and very long contexts.

### Improved
- **Batched generation is substantially faster on GCN/Vega GPUs**... the small-batch matrix-vector kernels now use the detected 64-lane SIMD width instead of being limited to wave32. Across the validated model set this raised generation by about 60% and prompt processing by about 35%, with output matching the previous path.
- **Decode projections are fused on GCN/Vega too**... compatible Q, K and V matrix-vector operations now share one Wave64 dispatch. Llama 2 7B Q4_0 generation improved from 55.57 to 57.37 t/s (+3.2%) with identical output; Q4_K/Q6_K models also pass deterministic A/B validation.
- **Long-context generation uses all available Wave64 workgroups**... attention for 256-, 512- and MLA 576/512-wide heads can split a long KV cache into 32 parts and merge them safely on a 64-lane GPU. GLM-4.7-Flash at 4096 context improved from 7.85 to 10.69 t/s (+36.2%).
- **Long prompt attention is optimized for GCN/Vega**... the parallel-prefill kernel now runs on Wave64 where its logical 16-lane groups are valid. Qwen3.5-4B at pp2048 improved from 542.44 to 567.76 t/s (+4.7%).
- **Dense prompt matrix multiplication overlaps tile loading with computation**... ToshGEMM now double-buffers dense tiles, measured +2.5% on an 8B model and +6.5% on Llama 2 7B, while keeping the existing path for MoE workloads where this scheduling regressed.

### Fixed
- **Wave64 vision attention no longer corrupts 72-wide heads**... the kernel now pins the same safe 16-lane logical subgroup used by the validated wave32 path instead of deriving an invalid reduction shape from the physical width.
- **Large-batch perplexity remains finite on Vega**... the previous context-4096 reproduction that produced NaN now completes six WikiText-2 chunks at `PPL 4.3980 +/- 0.08084`, with the model offloaded to Metal.
- **Image-to-image generation runs correctly on Vega**... SDXL Turbo now completes VAE encode, diffusion and tiled VAE decode on the GPU at 512x512. The validated run kept all 6.6 GB of model parameters in VRAM and loaded its matrix kernels at the native 64-lane width instead of moving the workload to CPU.

## [0.83.7] - 2026-07-30

### Improved
- **DFlash keeps draft logits on the GPU for greedy decoding**... Metal now computes one argmax per draft row and copies only the token ids instead of several full 248K-vocabulary rows, measured 68.39 → 70.72 t/s (+3.4%) on Qwen3.5-4B Q4_K_M with byte-identical output; DFlash now beats the 62.35 t/s autoregressive base by 13.4% and can activate automatically on dense/full-GPU models when its memory plan fits.
- **MTP now activates on dense and full-GPU models too**... the embedded head no longer requires `ncmoe > 0`; measured 79.51 vs 62.46 t/s autoregressive (+27%) on dense Qwen3.5-4B MTP Q4_K_M with 86.25% draft acceptance.
- **Speculative decoding no longer regresses on unpredictable content**... MTP and DFlash stop drafting when recent acceptance drops and re-probe periodically, so a low-overlap turn falls back toward autoregressive speed instead of paying the full draft cost, keeping the gains on predictable content.
- **Faster batched generation on Q4_K models**... the kernel keeps the quants raw and applies the scale once per chunk instead of expanding every value to a float first, measured 18% faster with four concurrent requests.
- **The same kernel reads each block's scales once instead of twice**... they were fetched again for every chunk of the block, measured a further 10% with four concurrent requests and 12% with eight.
- **And it unpacks each weight once instead of once per column**... the quant was masked and converted for every column that reuses it, measured a further 3%.

## [0.83.6] - 2026-07-28

### Improved
- **Faster generation when the engine serves several requests at once**... the batched matrix-vector kernel loads each activation chunk once for two rows instead of once per row, measured 12% faster with four concurrent requests on a dense Q4_K model.

### Fixed
- **Benchmark output now names the ToshLLM version that produced it**... the footer only carried the upstream build id, which stays the same across releases that change our engine, so a pasted result could not be attributed to a version.
- **The Infinity Fabric confirmation line no longer repeats**... it printed once per model load, filling a benchmark log with one copy per row.

## [0.83.5] - 2026-07-27

### Changed
- **Benchmark runs now identify the ToshLLM version that produced them**... the version is saved with each new result and shown in both the recent comparison and full history, so performance from different engine releases is not mistaken for the same build.
- **Much faster prompt processing on short prompts**... batches of 32 tokens or fewer now use a token tile they can actually fill, instead of computing padding: measured 34% and 32% faster at 16 and 32 tokens on a dense Q4_K model, and 27% and 24% on a dense Q5_K one. It applies to every quantization. Long prompts are unaffected, they already fill the tile. This is the path a chat turn takes once the cache is warm, where only the new tokens are processed.
- **Faster prompt processing on every quantized model**... the tiled matmul and its MoE variant write the dequantized tile in vector stores instead of one value at a time: measured 3.5% faster on a dense Q4_K model, 4.4 to 6% on MoE models that fit in VRAM, and 11.8% on a 35B MoE with experts offloaded to CPU.
- **Faster generation on K-quant models**... the q4_K and q5_K matrix-vector kernels read their quants in wide loads instead of one access at a time, measured about 1.5% faster generation on a dense Q4_K model.

## [0.83.4] - 2026-07-23

### Changed
- **The Infinity Fabric peer transfer now prints a confirmation line in the log**... the "peer transfer enabled" line shows at the normal log level so you can verify the path engaged, and the experimental first-copy probe from 0.83.3 (never validated on bridged hardware) is removed so it cannot disable the copy on a transient fault.

## [0.83.3] - 2026-07-23

### Added
- **Infinity Fabric Link for multi-GPU splits (experimental, opt-in)**... a new setting copies layer activations directly between GPUs that share a Metal peer group (a W6800X or Vega II Duo) instead of through system RAM; it can speed up prompt processing on some bridged multi-GPU configurations and does not change generation speed.

## [0.83.2] - 2026-07-23

### Fixed
- **The context-usage bar is now per chat**... it follows the open conversation and persists with the saved cache, instead of one shared value that only cleared when the app was reopened.
- **Multi-GPU env flags now appear in the startup log**... `TOSH_MGPU_PEER`, `TOSH_MGPU_EVENTS` and the device list show in the engine's env line, so an opt-in transport is verifiable from a pasted log.

## [0.83.1] - 2026-07-23

### Improved
- **Multi-GPU layer splits can use Infinity Fabric Link (experimental, opt-in)**... with `TOSH_MGPU_PEER=1` and two AMD GPUs in the same Metal peer group, layer activations move directly between their private VRAM buffers instead of round-tripping through system RAM. Off by default while it is validated on bridged hardware.

### Fixed
- **Generated SVG cannot inject active markup into the chat**... SVG blocks now load as isolated image resources instead of relying on regex-based HTML filtering.

## [0.83.0] - 2026-07-22

### Added
- **The native chat was rebuilt to match the llama.cpp chat experience**... agent tools that read, edit and run files and commands with per-step permission, a sandboxed JavaScript tool, richer Markdown rendering, advanced chat settings, per-message metrics, conversation forking, and audio, video attachments.
- **Model Context Protocol (MCP) support**... connect external MCP tool servers over HTTP/SSE or WebSocket (for example a web-search server) and the model can use their tools in chat, each call gated by permission.
- **Voice dictation in chat**... the microphone button transcribes your speech straight into the message box on-device (Apple's Speech framework, nothing leaves the Mac), and now offers to dictate or record audio for the model depending on what the model supports.
- **MoE experts adjust from the server panel**... raise or lower the CPU experts without opening Settings, on the main server and each added one; the control only appears for MoE models.

### Improved
- **The chat shows the model's real capabilities** (text, vision, audio, video) in the parameters panel, not only in router mode.
- **Every advanced chat setting now carries bilingual help**, and the image-size field is clamped to a valid range.
- **Videos warn about their token cost before sending**... a clip fills the context fast (~1,000 tokens per second at 1080p), and the estimate now accounts for its length and resolution.

### Fixed
- **A tools request that overflows the context no longer reports a bogus video error**... it now names the real cause and points at the context size.

## [0.82.8] - 2026-07-22

### Improved
- **Generation is faster deep into a conversation on AMD**... attention splits each 128-wide head's cache row across half as many lanes, +1.1% at 8k of context.
- **The same speedup reaches 64-wide attention heads**... models like Llama-3.2 split those cache rows too, +3.5% at 8k of context.
- **Small models generate faster**... the matmul now picks a wider row tile when the matrices are small, +1.5% on Llama-3.2-1B.

### Fixed
- **Generation no longer garbles on GCN/Vega GPUs with 128- or 512-wide attention heads**... the wave64 flash-attention kernel was built for a different simdgroup count than the host dispatched, corrupting the merge on models like Qwen3 and Gemma 4.
- **Vision decode no longer garbles on the 72-wide attention path**... the SigLIP/Qwen3-VL tower's head size fell on a reduction that assumed a power-of-two width; it now runs correctly (latent, only the encode path was ever reached in practice).

## [0.82.7] - 2026-07-21

### Improved
- **Generation is much faster deep into a conversation on AMD**... attention was giving each query head a single threadgroup and walking the whole cache from it, which left most of the GPU idle on models with few heads; at 8k of context Gemma 4 E2B goes 36 → 95 t/s, Gemma 3 4B 56 → 78, Qwen3.5-9B 37 → 45 and Qwen3-8B 40 → 46.
- **Narrow attention heads no longer waste half of each simdgroup**... models with 64-wide heads (Llama 3.2, gpt-oss) were computing at the cost of a 128-wide one, and now run two cache rows at once for the same work.

## [0.82.6] - 2026-07-21

### Improved
- **Long prompts are much faster on AMD**... attention now streams the KV cache through a blocked Metal kernel instead of writing the whole score matrix out to VRAM and reading it back three times; at 8k of context Qwen3-8B Q4_K_M goes 395 → 470 t/s of prefill, Qwen3.5-9B 484 → 550 and Gemma 3 4B 1068 → 1246, and the deeper the conversation the more it helps.
- **Images are described faster**... the vision tower runs its attention on that same kernel, cutting the encode of a 512x512 image from 228 to 129 ms on an RX 6700 XT.
- **Generation is faster on Q5_K and Q4_0 models**... both were splitting work across simdgroups the way other quants want it, which cost Q5_K 11.5% of its generation speed on an RX 6700 XT.
- **Prompt processing is faster on the lighter quants**... Q4_0, Q5_0, Q8_0 and the rest of the cheap-to-dequantize types now get their own matmul kernels with a wider tile per lane, up to 16% faster depending on the type.

## [0.82.5] - 2026-07-20

### Improved
- **Prompt processing is much faster on AMD**... the Metal matmul now covers a 64x64 output tile per threadgroup instead of 64x32, cutting how many times each weight is re-read; Qwen3-8B Q4_K_M goes 480 → 692 t/s of prefill on an RX 6700 XT, with generation unchanged.
- **K-quant models dequantize with far fewer loads**... Q4_K and Q5_K now read each 16-byte window with a single 128-bit load instead of eight 16-bit ones; a 9B Q5_K_M gains a further +13% prefill.

### Changed
- **The AMD stability switch is gone from Settings**... the engine now turns the Metal concurrency off by itself on discrete GPUs, so there is no toggle left to get wrong (`GGML_METAL_CONCURRENCY_ENABLE=1` forces it back on for testing).

## [0.82.4] - 2026-07-18

### Added
- **Ternary Q2_0 models now load** ([#41](https://github.com/engeldlgado/toshllm/issues/41))... mainline's Q2_0 type runs Prism ML's Ternary Bonsai GGUFs on Metal instead of failing with "invalid ggml type 42".
- **Manual vision projector selection** ([#35](https://github.com/engeldlgado/toshllm/issues/35))... pick a specific `mmproj`, keep auto-pairing, or turn vision off, from each model card.
- **DFlash speculative decoding (experimental)**... a downloaded per-model draft with Off/Auto/Forced modes; Auto only engages on MoE with CPU-offloaded experts, up to +21% generation on an RX 6700 XT.
- **DFlash sizes itself to the GPU**... Auto budgets the weights, both KV caches and the VRAM reserve before launch, then offloads draft layers or stays off, and warns if VRAM stays above 95%.

### Changed
- **The vision projector no longer downloads with the model**... a separate button fetches the `mmproj` on demand, so text-only users skip the file.
- **On AMD the KV cache picker offers only the fast types** (f16/q8_0/q4_0)... the rest have no AMD Flash Attention kernel and ran ~3.7x slower.
- **The DFlash control shows when it is actually running**... the bolt lights up with the live draft-acceptance rate only when the engine truly engaged the draft, not just when Auto is picked.
- **Sharing a benchmark uses the benchmark's own config**... the share panel publishes the settings shown in Run benchmark, not the global ones.
- **Downloaded models remember their source repo**... for on-demand sibling downloads (projector, DFlash draft).

### Fixed
- **An unsupported quantization gives a clear reason**... a model the engine can't read now says the quant isn't supported instead of "model file damaged or incomplete".
- **Persisted KV caches survive a KV-type change**... slot files are kept per KV type, so switching f16↔q8_0 cold-prefills cleanly instead of logging a failed restore.

## [0.82.3] - 2026-07-17

### Added
- **Share your benchmarks to [toshllm.com](https://toshllm.com) from the app**... Benchmarks → Share with the community runs the standard workload and, after you review the exact data, submits it signed per-install (no account needed); opt-in, nothing leaves your machine until you confirm.

### Fixed
- **Image generation no longer aborts on AMD GCN/Vega (wave64) GPUs** ([#39](https://github.com/engeldlgado/toshllm/issues/39))... an op the wave64 backend has no kernel for (e.g. the VAE encode's small matmul in img2img) now falls to CPU instead of crashing the whole run.
- **Added servers now follow the global Settings** ([#40](https://github.com/engeldlgado/toshllm/issues/40))... they used to freeze a snapshot at creation, so changing e.g. Context never reached them; now they inherit everything except the fields you change on their own card (a pin-slash button restores full inheritance), and the card gained a Context row.

## [0.82.2] - 2026-07-17

### Improved
- **MoE generation with offloaded experts is faster again**... staged expert uploads now ride the compute queue instead of waiting on each one; +2% to +14% depending on how many layers are on the CPU (35B at ncmoe 24: 23.8 → 27.0 t/s), output byte-identical, validated across five MoE models.

### Added
- **Experimental multi-GPU hand-off over shared events** (`TOSH_MGPU_EVENTS=1` in Extra arguments)... the layer hand-off between cards stops draining both GPUs and round-tripping the CPU on every token; off by default, for multi-GPU testers.

### Fixed
- **The real-generation benchmark's prompt speed is meaningful again**... its prompt was too short to be a real prefill, so it read far below the true number; it now uses a ~512-token prompt.

## [0.82.1] - 2026-07-16

### Added
- **Real-generation benchmark**... measures against a real llama-server the way the chat runs, MTP included (the raw benchmark under-reports MoE MTP models by 25-47%): one discarded warm-up, three repetitions, median.
- **Context depth in Benchmarks (-d)**... measures speed deep into a conversation instead of only at an empty context; the workload fields (-p/-n/-d) now sit behind an "Advanced" check.
- **MTP acceptance in the chat**... each response shows the fraction of drafted tokens that were right, next to its speed.
- **The Server card names the current bottleneck**... VRAM bandwidth (full-GPU) or RAM bandwidth (MoE experts on CPU), so it's clear what upgrade would actually help.
- **`TOSH_MOE_PROFILE=1` in Extra arguments**... logs the engine's host↔GPU traffic every 5 s in the server log, for diagnostics.

### Improved
- **MoE generation with offloaded experts is 3-5% faster**... the engine batches each CPU layer's reads from the GPU into one round-trip; output is byte-identical, validated across six MoE models.

### Fixed
- **"Remember conversations" is no longer blocked by vision-capable models**... it engages whenever possible and only skips (silently) while the projector is actually loaded; turning the vision eye off re-enables it.

## [0.82.0] - 2026-07-15

### Removed
- **The experimental TurboQuant engine is gone**... the bundled engine matches it on a dense Qwen3-8B (474 vs 475 t/s prompt).
- **The `turbo2/3/4` KV cache types go with it**... a saved one falls back to a standard type.

### Improved
- **Conversation persistence now works on the bundled engine**, where it was limited to the experimental one... reopening an 8.6k-token prompt after an engine restart takes 0.9 s instead of 24.8 s.
- **Vision models keep Flash Attention on the GPU**... describing an image costs 248-358 MB of VRAM instead of 3.4-4.7 GB.
- **Browse reads each candidate's GGUF header** ([#36](https://github.com/engeldlgado/toshllm/issues/36))... a Mixture-of-Experts model whose filename hides it is no longer sized against full VRAM.
- **The engine stamps the ToshLLM version in its startup log**... llama.cpp's own build number only identifies the upstream commit.

### Fixed
- **Gemma 4 vision no longer crashes the server**... forcing Flash Attention on used to split the projector graph and bind a null buffer.
- **The engine picker no longer switches itself to "External"**... it stored a path, which differs between two installs that share one settings domain.
- **Model detection reads the GGUF header instead of the filename**... a renamed MoE keeps its VRAM estimate, and a split GGUF counts as one model.
- **The Models tab reflects your per-model expert offload**... the fit estimate follows the saved ncmoe and shows it as a chip.

## [0.81.67] - 2026-07-14

### Improved
- **MoE prompt processing on GCN/Vega now uses the tiled matmul** ([#29](https://github.com/engeldlgado/toshllm/issues/29))... expert layers were still going through the mat-vec kernels during prefill; `TOSH_W64_MMID_PREFILL_DISABLE=1` in Extra arguments reverts to the old route.
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
- **Image generation no longer times out on eGPUs** ([#33](https://github.com/engeldlgado/toshllm/issues/33))... the image engine now gets the same private-VRAM buffer fix the LLM engine got in 0.81.30.
- **Chat text no longer cuts off with "…" on indented lines** at certain window widths ([#32](https://github.com/engeldlgado/toshllm/issues/32)).

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
- **Qwen-Image no longer crashes at the end of generation**... its 3D VAE uses an operation (`IM2COL_3D`) that Metal doesn't implement, so the run aborted right at the decode step after minutes of sampling ([#19](https://github.com/engeldlgado/toshllm/issues/19)). The VAE now runs on the CPU for this model automatically: decoding takes a few extra seconds and the image comes out. A Metal kernel to put it back on the GPU is planned.

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
- **Benchmark workload sizes**... two new fields choose how many prompt tokens (-p) and generated tokens (-n) the benchmark measures, while keeping every ToshLLM optimization active ([#22](https://github.com/engeldlgado/toshllm/issues/22)). Defaults stay at the comparable pp512/tg128; each result records its sizes and the history labels non-standard runs.
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
