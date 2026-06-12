import SwiftUI

/// Built-in app documentation, in Spanish and English.
struct DocsView: View {
    @EnvironmentObject var loc: Localizer
    @State private var selected: Int = 0

    var body: some View {
        let sections = DocsContent.sections(spanish: loc.isSpanish)
        HSplitView {
            List(0..<sections.count, id: \.self, selection: Binding(
                get: { selected }, set: { selected = $0 ?? 0 })
            ) { i in
                Label(sections[i].title, systemImage: sections[i].icon).tag(i)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 200, idealWidth: 230, maxWidth: 280)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(sections[selected].title).font(.title.bold())
                    RichText(text: sections[selected].body)
                        .frame(maxWidth: 700, alignment: .leading)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct DocSection {
    let title: String
    let icon: String
    let body: String
}

enum DocsContent {
    static func sections(spanish: Bool) -> [DocSection] { spanish ? es : en }

    static let es: [DocSection] = [
        DocSection(title: "Qué es ToshLLM", icon: "sparkles", body: """
ToshLLM ejecuta modelos de lenguaje (LLM) **localmente** en Macs Intel con GPU AMD, usando aceleración Metal. Nada sale de tu equipo: sin nube, sin cuentas, sin costos por token.

Por dentro usa **llama.cpp** con parches específicos para GPUs AMD discretas en macOS, empaquetado dentro de la propia app — no necesitas instalar nada más.

**Requisitos:**
- Mac con macOS 14 o superior
- GPU AMD con soporte Metal (probado con RX 6700 XT 12 GB)
- 16 GB de RAM mínimo (32 GB recomendado para modelos MoE grandes)
"""),
        DocSection(title: "Inicio rápido", icon: "play.circle", body: """
1. Ve a **Modelos** y descarga uno del catálogo (la app te indica cuáles caben en tu equipo con etiquetas de color).
2. Pulsa **Usar** en el modelo descargado — los parámetros se ajustan solos.
3. Ve a **Inicio** y pulsa **Iniciar servidor**.
4. Abre **Chat** y conversa.

La etiqueta de cada modelo indica su compatibilidad:
- **GPU completa**: cabe entero en VRAM, máxima velocidad
- **Híbrido GPU+CPU**: modelos MoE repartidos entre VRAM y RAM, buen rendimiento
- **Lento**: funciona pero con velocidad limitada
- **No cabe**: excede la memoria de tu equipo
"""),
        DocSection(title: "Las pestañas", icon: "square.grid.2x2", body: """
**Inicio** — Resumen del equipo detectado (CPU, RAM, GPU, VRAM), control del servidor, estadísticas en vivo y el modelo recomendado para tu hardware.

**Chat** — Conversaciones con el modelo: historial persistente, múltiples conversaciones (⌘N), prompt de sistema, regenerar respuestas, copiar mensajes y bloques de código, velocidad por mensaje.

**Modelos** — Modelos locales detectados en `~/models`, catálogo curado con estimaciones de memoria para tu equipo, buscador de Hugging Face y descargas con progreso. Puedes eliminar modelos (van a la Papelera).

**Benchmarks** — Mide la velocidad real del modelo activo (procesamiento de prompt y generación) con tu configuración actual. Guarda historial comparativo con gráfica.

**Ajustes** — Todos los parámetros del motor, perfiles guardables, idioma y opciones de la app. Cada opción tiene una descripción al pasar el cursor.
"""),
        DocSection(title: "Modelos MoE y memoria", icon: "memorychip", body: """
Los modelos **MoE (Mixture of Experts)** como Qwen3.6-35B-A3B tienen muchos parámetros totales (35B) pero solo activan unos pocos por token (3B). Esto permite calidad de modelo grande a velocidad de modelo pequeño.

El truco para GPUs con poca VRAM es **repartir el modelo**:
- La atención y los expertos que quepan van a la **VRAM** (rápida)
- El resto de expertos queda en la **RAM** y los procesa el CPU

El parámetro **Expertos MoE en CPU** (`--n-cpu-moe`) controla cuántas capas de expertos van al CPU. La app lo calcula automáticamente al elegir un modelo. Si la VRAM se satura (velocidad colapsa de golpe), súbelo; si te sobra VRAM, bájalo.

**Importante**: en este modo la velocidad de generación está limitada por el **ancho de banda de tu RAM**, no por la GPU. Con DDR4 esperarás ~15-25 t/s en modelos 35B; equipos DDR5 alcanzan ~38 t/s con la misma configuración.
"""),
        DocSection(title: "Parámetros explicados", icon: "slider.horizontal.3", body: """
**Capas en GPU (-ngl)** — Cuántas capas suben a la VRAM. 99 = todas (recomendado). Valores mayores al número de capas del modelo equivalen a "todas".

**Expertos MoE en CPU** — Ver sección de modelos MoE.

**Reserva de VRAM** — Memoria que se deja libre para el sistema. 1024 MB es seguro.

**Copiar pesos a VRAM (--no-mmap)** — Esencial en GPU dedicada: sin esto los pesos se leen por PCIe en cada token y la velocidad cae ~6×.

**Bloquear modelo en RAM (--mlock)** — Evita que macOS mueva el modelo a swap. Útil con MoE grandes si tienes RAM de sobra.

**Contexto** — Tamaño máximo de la conversación en tokens. Más contexto = más memoria de KV cache.

**KV cache claves/valores (-ctk / -ctv)** — Cuantización de la memoria de atención:
- Claves `q8_0`: mitad de memoria, costo casi nulo (recomendado)
- Valores cuantizados: requiere Flash Attention y **en GPU AMD lo fuerza al CPU**, bajando la generación ~3×. Úsalo solo para contextos enormes.

**Flash Attention** — Atención eficiente en memoria. `auto` es lo correcto en GPU AMD.

**Estabilidad AMD dGPU** — Desactiva la concurrencia de Metal. **Imprescindible**: sin esto la salida se corrompe en GPUs AMD discretas.

**Hilos de CPU** — Para la parte que corre en CPU. Los núcleos físicos suelen ser el óptimo.
"""),
        DocSection(title: "Motores de inferencia", icon: "engine.combustion", body: """
La app incluye **dos motores** y admite externos (Ajustes → Avanzado):

**Integrado (oficial)** — llama.cpp oficial con parches AMD. Recomendado para todo uso. Soporta las arquitecturas más recientes (Qwen 3.6, MTP).

**TurboQuant (experimental)** — Motor con cuantización extrema del KV cache (tipos `turbo2/3/4`, basados en investigación de compresión presentada en ICLR 2026). Reduce la memoria de contexto hasta ~6×, permitiendo contextos de 100k+ tokens en GPUs de 12 GB. Costo: la generación baja (~15% en MoE grandes, mucho más en modelos pequeños). La mejor combinación medida: claves `turbo4` + valores `turbo3` + Flash Attention `on`.

**Externo** — Cualquier binario `llama-server` tuyo, para probar builds propias.
"""),
        DocSection(title: "Perfiles", icon: "person.2", body: """
Un perfil guarda **toda** la configuración: modelo, motor, parámetros de memoria y contexto. Se crean en Ajustes → Perfiles escribiendo un nombre y pulsando "Guardar actual".

Perfiles típicos:
- **Diario (MTP)**: modelo MTP + `--spec-type draft-mtp` en argumentos extra → máxima velocidad de chat
- **Contexto XL**: motor TurboQuant + claves `turbo4`/valores `turbo3` + contexto 64k → documentos largos

Al aplicar un perfil, reinicia el servidor para que tome efecto.
"""),
        DocSection(title: "MTP: generación acelerada", icon: "hare", body: """
**MTP (Multi-Token Prediction)** es una técnica donde el modelo predice varios tokens por pasada y luego los verifica — sin ninguna pérdida de calidad (solo acepta lo que habría generado de todas formas).

Resultado medido en este equipo: **+34% de velocidad de generación** (19.3 → 25.7 t/s en Qwen3.6-35B) con 82% de aceptación.

Para usarlo necesitas dos cosas:
1. Un GGUF con cabezal MTP (busca repos con "MTP" en el nombre, p. ej. `Qwen3.6-35B-A3B-MTP-GGUF` de unsloth — los GGUF normales no lo traen)
2. Agregar `--spec-type draft-mtp` en Ajustes → Avanzado → Argumentos extra

Funciona con el motor Integrado. El perfil "Diario (MTP)" ya lo configura todo.
"""),
        DocSection(title: "API para desarrolladores", icon: "terminal", body: """
Con el servidor activo, tienes una **API compatible con OpenAI** en `http://127.0.0.1:8080` (puerto configurable). Funciona con cualquier librería o app que hable ese protocolo.

Ejemplo con curl:

```bash
curl http://127.0.0.1:8080/v1/chat/completions \\
  -H "Content-Type: application/json" \\
  -d '{
    "messages": [{"role": "user", "content": "Hola"}],
    "stream": true,
    "temperature": 0.7
  }'
```

Endpoints útiles:
- `POST /v1/chat/completions` — chat (streaming opcional)
- `GET /v1/models` — modelo cargado
- `GET /health` — estado del servidor

También hay un chat web minimalista en la raíz (`http://127.0.0.1:8080`) para usar desde el navegador.

**Conectar VS Code y asistentes de código** (Continue, Cline, Copilot con modelo propio…):
- URL base: `http://127.0.0.1:8080/v1` · nombre de modelo: cualquiera · clave API: la de Ajustes solo si activaste la protección.
- **Sube el Contexto a 32k o más**: estos clientes envían prompts enormes (instrucciones + archivos abiertos) y con 16k el servidor rechaza la petición. Compensa la memoria cuantizando las claves del KV cache a `q8_0`.
- Los modelos razonadores "piensan" antes de responder y muchos clientes no muestran esa fase: parece que **se quedó colgado** cuando en realidad está generando. Activa "Razonamiento como texto" en Ajustes → Inferencia, o usa un modelo no razonador para código.
- La **primera respuesta tarda**: procesar un prompt de 15k tokens lleva 1-2 minutos en un MoE grande. Si el cliente corta antes, sube su timeout.
"""),
        DocSection(title: "Rendimiento de referencia", icon: "gauge.high", body: """
Números medidos en el equipo de desarrollo (RX 6700 XT 12 GB, DDR4, macOS):

**Qwen3-8B Q4** (todo en VRAM): ~101 t/s prompt, ~57 t/s generación

**Qwen3.6-35B-A3B Q4** (MoE híbrido, ncmoe 24):
- Normal: ~123 t/s prompt, ~18.6 t/s generación
- Con MTP: ~25.7 t/s generación (+34%)
- Con TurboQuant (contexto XL): ~68 t/s prompt, ~15.7 t/s generación

La generación de modelos MoE híbridos está limitada por el ancho de banda de la RAM: una GPU más potente no la mejora, pero RAM DDR5 sí (hasta ~2×).
"""),
        DocSection(title: "Solución de problemas", icon: "wrench.and.screwdriver", body: """
**macOS bloquea la app al instalarla** — Las versiones descargadas aún no están notarizadas por Apple: ve a Ajustes del Sistema → Privacidad y seguridad y pulsa "Abrir de todos modos" (solo la primera vez por versión).

**La salida es texto sin sentido** — Verifica que "Estabilidad AMD dGPU" esté activada en Ajustes. Es la causa #1 en GPUs AMD discretas.

**Va muy lento (2-8 t/s)** — Activa "Copiar pesos a VRAM (--no-mmap)". Si ya está activo, la VRAM puede estar saturada: sube "Expertos MoE en CPU" un par de capas.

**La velocidad colapsa de repente** — VRAM desbordada. Sube el ncmoe o reduce el contexto.

**El modelo no carga** — Puede ser una arquitectura demasiado nueva para el motor. Prueba el motor Integrado (es el más actualizado). Las variantes "MTP" requieren motores recientes.

**Error con valores de KV cuantizados** — Cuantizar valores requiere Flash Attention en `on`. En GPU AMD eso reduce la velocidad; valora si lo necesitas.

**El servidor no responde tras cambiar ajustes** — Los cambios aplican al reiniciar el servidor (Detener → Iniciar).

**La velocidad se degrada con el uso / el motor llega a 25-30 GB de RAM** — Dos causas se suman: el contexto crece con la conversación (normal, la autocompactación lo mitiga) y el motor guarda una caché de prompts en RAM que crece con el uso. Limita "Caché de prompts en RAM" en Ajustes (2 GB por defecto) y, si tienes margen, activa --mlock para que el modelo no caiga a swap.

**Desde VS Code u otro cliente se queda "pensando"** — El modelo está razonando o procesando un prompt enorme; el cliente no muestra esa fase. Ver la sección "API para desarrolladores".
"""),
        DocSection(title: "Créditos y licencias", icon: "heart", body: """
ToshLLM es desarrollado por **Engelbert Delgado** ([@engeldlgado](https://github.com/engeldlgado)).

Construido sobre el trabajo de:
- **llama.cpp** (ggml-org) — el motor de inferencia
- **iRon-Llama** (Basten7) — investigación de parches Metal para GPU AMD en Mac Intel

Si la app te resulta útil, puedes apoyar el desarrollo desde **Acerca de → Donar** (Binance Pay).
"""),
    ]

    static let en: [DocSection] = [
        DocSection(title: "What is ToshLLM", icon: "sparkles", body: """
ToshLLM runs large language models (LLMs) **locally** on Intel Macs with AMD GPUs, using Metal acceleration. Nothing leaves your machine: no cloud, no accounts, no per-token costs.

Under the hood it uses **llama.cpp** with patches specific to discrete AMD GPUs on macOS, bundled inside the app itself — nothing else to install.

**Requirements:**
- Mac with macOS 14 or later
- AMD GPU with Metal support (tested on RX 6700 XT 12 GB)
- 16 GB RAM minimum (32 GB recommended for large MoE models)
"""),
        DocSection(title: "Quick start", icon: "play.circle", body: """
1. Go to **Models** and download one from the catalog (the app shows which ones fit your machine with color badges).
2. Press **Use** on the downloaded model — parameters adjust automatically.
3. Go to **Home** and press **Start server**.
4. Open **Chat** and talk.

Each model's badge shows compatibility:
- **Full GPU**: fits entirely in VRAM, maximum speed
- **GPU+CPU hybrid**: MoE models split between VRAM and RAM, good performance
- **Slow**: works but with limited speed
- **Won't fit**: exceeds your machine's memory
"""),
        DocSection(title: "The tabs", icon: "square.grid.2x2", body: """
**Home** — Detected hardware summary (CPU, RAM, GPU, VRAM), server control, live stats and the recommended model for your hardware.

**Chat** — Conversations with the model: persistent history, multiple chats (⌘N), system prompt, regenerate responses, copy messages and code blocks, per-message speed.

**Models** — Local models detected in `~/models`, curated catalog with memory estimates for your machine, Hugging Face search and downloads with progress. You can delete models (they go to Trash).

**Benchmarks** — Measures real speed of the active model (prompt processing and generation) with your current settings. Keeps comparative history with a chart.

**Settings** — All engine parameters, savable profiles, language and app options. Every option has a tooltip on hover.
"""),
        DocSection(title: "MoE models & memory", icon: "memorychip", body: """
**MoE (Mixture of Experts)** models like Qwen3.6-35B-A3B have many total parameters (35B) but only activate a few per token (3B). This gives big-model quality at small-model speed.

The trick for low-VRAM GPUs is **splitting the model**:
- Attention and as many experts as fit go to **VRAM** (fast)
- The remaining experts stay in **RAM**, processed by the CPU

The **MoE experts on CPU** parameter (`--n-cpu-moe`) controls how many expert layers go to the CPU. The app calculates it automatically when you pick a model. If VRAM saturates (speed suddenly collapses), raise it; if you have VRAM headroom, lower it.

**Important**: in this mode, generation speed is limited by your **RAM bandwidth**, not the GPU. With DDR4 expect ~15-25 t/s on 35B models; DDR5 machines reach ~38 t/s with the same setup.
"""),
        DocSection(title: "Parameters explained", icon: "slider.horizontal.3", body: """
**GPU layers (-ngl)** — How many layers go to VRAM. 99 = all (recommended). Any value above the model's layer count means "all".

**MoE experts on CPU** — See the MoE section.

**VRAM reserve** — Memory left free for the system. 1024 MB is safe.

**Copy weights to VRAM (--no-mmap)** — Essential on discrete GPUs: without it, weights are read over PCIe on every token and speed drops ~6×.

**Lock model in RAM (--mlock)** — Prevents macOS from swapping the model out. Useful with large MoE if you have spare RAM.

**Context** — Maximum conversation size in tokens. More context = more KV cache memory.

**KV cache keys/values (-ctk / -ctv)** — Quantization of attention memory:
- Keys `q8_0`: half the memory at near-zero cost (recommended)
- Quantized values: requires Flash Attention and **on AMD GPUs forces it onto the CPU**, dropping generation ~3×. Use only for huge contexts.

**Flash Attention** — Memory-efficient attention. `auto` is right on AMD GPUs.

**AMD dGPU stability** — Disables Metal concurrency. **Required**: without it, output corrupts on discrete AMD GPUs.

**CPU threads** — For the CPU-side work. Physical core count is usually optimal.
"""),
        DocSection(title: "Inference engines", icon: "engine.combustion", body: """
The app ships **two engines** and supports external ones (Settings → Advanced):

**Bundled (official)** — Official llama.cpp with AMD patches. Recommended for everything. Supports the newest architectures (Qwen 3.6, MTP).

**TurboQuant (experimental)** — Engine with extreme KV cache quantization (`turbo2/3/4` types, based on compression research presented at ICLR 2026). Cuts context memory up to ~6×, enabling 100k+ token contexts on 12 GB GPUs. Cost: generation drops (~15% on large MoE, much more on small models). Best measured combo: keys `turbo4` + values `turbo3` + Flash Attention `on`.

**External** — Any `llama-server` binary of yours, for testing custom builds.
"""),
        DocSection(title: "Profiles", icon: "person.2", body: """
A profile saves **everything**: model, engine, memory and context parameters. Create them in Settings → Profiles by typing a name and pressing "Save current".

Typical profiles:
- **Daily (MTP)**: MTP model + `--spec-type draft-mtp` in extra arguments → fastest chat
- **Context XL**: TurboQuant engine + `turbo4` keys/`turbo3` values + 64k context → long documents

After applying a profile, restart the server for it to take effect.
"""),
        DocSection(title: "MTP: faster generation", icon: "hare", body: """
**MTP (Multi-Token Prediction)** is a technique where the model predicts several tokens per pass and then verifies them — with zero quality loss (it only accepts what it would have generated anyway).

Measured result on this machine: **+34% generation speed** (19.3 → 25.7 t/s on Qwen3.6-35B) with 82% acceptance.

You need two things:
1. A GGUF with the MTP head (look for repos with "MTP" in the name, e.g. unsloth's `Qwen3.6-35B-A3B-MTP-GGUF` — regular GGUFs don't include it)
2. Add `--spec-type draft-mtp` in Settings → Advanced → Extra arguments

Works with the Bundled engine. The "Daily (MTP)" profile configures everything.
"""),
        DocSection(title: "API for developers", icon: "terminal", body: """
With the server running, you get an **OpenAI-compatible API** at `http://127.0.0.1:8080` (configurable port). Works with any library or app that speaks the protocol.

Example with curl:

```bash
curl http://127.0.0.1:8080/v1/chat/completions \\
  -H "Content-Type: application/json" \\
  -d '{
    "messages": [{"role": "user", "content": "Hello"}],
    "stream": true,
    "temperature": 0.7
  }'
```

Useful endpoints:
- `POST /v1/chat/completions` — chat (optional streaming)
- `GET /v1/models` — loaded model
- `GET /health` — server status

There's also a minimal web chat at the root (`http://127.0.0.1:8080`) for browser use.

**Connecting VS Code and coding assistants** (Continue, Cline, Copilot with a custom model…):
- Base URL: `http://127.0.0.1:8080/v1` · model name: anything · API key: the one in Settings only if you enabled protection.
- **Raise Context to 32k or more**: these clients send huge prompts (instructions + open files) and at 16k the server rejects the request. Offset the memory by quantizing KV cache keys to `q8_0`.
- Reasoning models "think" before answering and many clients don't display that phase: it **looks hung** while it's actually generating. Enable "Reasoning as plain text" in Settings → Inference, or use a non-reasoning model for coding.
- The **first response takes a while**: processing a 15k-token prompt takes 1-2 minutes on a large MoE. If the client gives up earlier, raise its timeout.
"""),
        DocSection(title: "Reference performance", icon: "gauge.high", body: """
Numbers measured on the development machine (RX 6700 XT 12 GB, DDR4, macOS):

**Qwen3-8B Q4** (fully in VRAM): ~101 t/s prompt, ~57 t/s generation

**Qwen3.6-35B-A3B Q4** (hybrid MoE, ncmoe 24):
- Normal: ~123 t/s prompt, ~18.6 t/s generation
- With MTP: ~25.7 t/s generation (+34%)
- With TurboQuant (XL context): ~68 t/s prompt, ~15.7 t/s generation

Hybrid MoE generation is RAM-bandwidth-bound: a faster GPU won't improve it, but DDR5 RAM will (up to ~2×).
"""),
        DocSection(title: "Troubleshooting", icon: "wrench.and.screwdriver", body: """
**macOS blocks the app on install** — Downloaded releases are not Apple-notarized yet: go to System Settings → Privacy & Security and click "Open Anyway" (once per version).

**Output is gibberish** — Check that "AMD dGPU stability" is enabled in Settings. It's the #1 cause on discrete AMD GPUs.

**Very slow (2-8 t/s)** — Enable "Copy weights to VRAM (--no-mmap)". If already on, VRAM may be saturated: raise "MoE experts on CPU" a couple of layers.

**Speed suddenly collapses** — VRAM overflow. Raise ncmoe or reduce context.

**Model won't load** — May be an architecture too new for the engine. Try the Bundled engine (it's the most up to date). "MTP" variants require recent engines.

**Error with quantized KV values** — Quantized values require Flash Attention `on`. On AMD GPUs that reduces speed; consider whether you need it.

**Server ignores new settings** — Changes apply on server restart (Stop → Start).

**Speed degrades over time / the engine reaches 25-30 GB of RAM** — Two causes add up: context grows with the conversation (normal, auto-compaction mitigates it) and the engine keeps a prompt cache in RAM that grows with use. Cap "Prompt cache in RAM" in Settings (2 GB by default) and, if you have headroom, enable --mlock so the model never falls into swap.

**It hangs "thinking" from VS Code or another client** — The model is reasoning or processing a huge prompt; the client doesn't display that phase. See the "API for developers" section.
"""),
        DocSection(title: "Credits & licenses", icon: "heart", body: """
ToshLLM is developed by **Engelbert Delgado** ([@engeldlgado](https://github.com/engeldlgado)).

Built on the work of:
- **llama.cpp** (ggml-org) — the inference engine
- **iRon-Llama** (Basten7) — Metal patch research for AMD GPUs on Intel Macs

If the app is useful to you, you can support development from **About → Donate** (Binance Pay).
"""),
    ]
}
