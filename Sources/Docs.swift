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

**Chat** — Conversaciones con el modelo: historial persistente, múltiples conversaciones (⌘N), prompt de sistema, regenerar respuestas, copiar mensajes y bloques de código, velocidad por mensaje, adjuntar imágenes (modelos con visión) y archivos de texto/PDF (hasta 40 MB, con OCR automático para PDFs escaneados).

**Modelos** — Modelos locales detectados en `~/models` (puedes cambiar la carpeta en Ajustes), catálogo curado con estimaciones de memoria para tu equipo, buscador de Hugging Face y descargas con progreso. Puedes eliminar modelos (van a la Papelera).

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
        DocSection(title: "Generación de imágenes", icon: "photo.on.rectangle.angled", body: """
El interruptor **Chat / Imágenes** en la parte superior de la ventana cambia al estudio de imágenes (beta, motor `stable-diffusion.cpp` sobre la misma pila Metal).

**Catálogo**: la app recomienda un modelo según tu VRAM (Z-Image Turbo, Flux.2 klein, Flux.2 dev, Qwen-Image, SDXL Turbo…). El badge de cada uno indica si cabe en tu GPU; hay un margen de tolerancia porque macOS reporta algo menos de VRAM utilizable que la física de la tarjeta.

**Controles principales**: proporción/tamaño (ajustado a la cuadrícula del modelo y limitado por tu VRAM), pasos, CFG, semilla (fija una para reproducir el mismo resultado) y formato de salida. **Imagen a imagen**: sube una imagen inicial y ajusta la Intensidad (bajo conserva la composición, alto la reinventa). **Descargar a CPU**: mantiene los pesos en RAM y los transfiere a VRAM por etapas, para modelos grandes en GPUs con poca memoria (más lento, pero cabe).

**Instancias paralelas**: en Macs con varias GPUs puedes añadir instancias adicionales, cada una con su propio modelo, GPU y configuración, y generar varias variaciones a la vez desde un solo botón Generar. Dos instancias en la misma GPU muestran una advertencia (puede colgar la tarjeta en GPUs AMD).
"""),
        DocSection(title: "Parámetros explicados", icon: "slider.horizontal.3", body: """
**Capas en GPU (-ngl)** — Cuántas capas suben a la VRAM. 99 = todas (recomendado). Valores mayores al número de capas del modelo equivalen a "todas".

**Expertos MoE en CPU** — Ver sección de modelos MoE.

**Reserva de VRAM** — Memoria que se deja libre para el sistema. 1024 MB es seguro.

**Copiar pesos a VRAM (--no-mmap)** — Esencial en GPU dedicada: sin esto los pesos se leen por PCIe en cada token y la velocidad cae ~6×.

**Bloquear modelo en RAM (--mlock)** — Evita que macOS mueva el modelo a swap. Útil con MoE grandes si tienes RAM de sobra.

**Contexto** — Tamaño máximo de la conversación en tokens. Más contexto = más memoria de KV cache.

**KV cache claves/valores (-ctk / -ctv)** — Cuantización de la memoria de atención. La mejor combinación depende de si usas el kernel **Flash Attention AMD**:
- **Sin el kernel** (motor oficial): cuantiza solo las claves — `q8_0` (mitad de memoria, costo casi nulo, recomendado) o `q4_0` (un cuarto), dejando los valores en `f16`. Cuantizar también los valores obligaría a Flash Attention en CPU (~3× más lento).
- **Con el kernel** (Experimental + Flash Attention AMD): cualquier combinación estándar (`f16`/`q8_0`/`q4_0` en claves y valores) corre en GPU a velocidad plena. Máximo ahorro: `q8_0/q8_0` o `q4_0/q4_0`; comprimir solo las claves y mantener calidad en los valores: `q8_0/f16` o `q4_0/f16`.

**Flash Attention** — Atención eficiente en memoria. `auto` es lo correcto en GPU AMD.

**Estabilidad AMD dGPU** — Desactiva la concurrencia de Metal. **Imprescindible**: sin esto la salida se corrompe en GPUs AMD discretas.

**Hilos de CPU** — Para la parte que corre en CPU. Los núcleos físicos suelen ser el óptimo.
"""),
        DocSection(title: "Motores de inferencia", icon: "engine.combustion", body: """
La app incluye **dos motores** y admite externos (Ajustes → Avanzado):

**Integrado (oficial)** — llama.cpp oficial con parches AMD. Recomendado para todo uso. Soporta las arquitecturas más recientes (Qwen 3.6, MTP).

**Experimental (TurboQuant)** — Motor con cuantización extrema del KV cache (tipos `turbo2/3/4`, basados en investigación de compresión presentada en ICLR 2026). Reduce la memoria de contexto hasta ~6×, permitiendo contextos de 100k+ tokens en GPUs de 12 GB. Costo: la generación baja algo frente al mismo modelo sin cuantizar el KV. La mejor combinación medida: claves `turbo4` + valores `turbo3`.

Al elegir este motor aparece el interruptor **Kernel Flash Attention AMD**. Ejecuta la atención —tanto el procesamiento del prompt como la generación— en la GPU AMD mediante un kernel Metal propio (cabezas de 128, 256 y 512 —cubre Gemma 4—; tipos de KV f16, q8_0, q4_0 en cualquier combinación claves/valores, y turbo2/3/4). Es clave con KV cuantizado o turbo: como esos tipos **obligan** a Flash Attention, sin el kernel la atención cae a CPU y se desploma con la profundidad; con el kernel todo se queda en GPU y la generación aguanta la profundidad (ej. ~33 t/s a 4k de contexto en un 8B).

**Externo** — Cualquier binario `llama-server` tuyo, para probar builds propias.

**ToshGEMM**, activo por defecto en ambos motores, es un kernel de multiplicación de matrices en mosaico (tiled) escrito a medida para el procesamiento de prompt en GPUs AMD, que en esta GPU llevó el prompt de un 8B de ~101 a ~312 t/s (~3×). No es un interruptor: corre siempre que el modelo procesa el prompt en GPU.

Para modelos MoE con expertos en RAM (ncmoe > 0), el interruptor **Prefetch de expertos MoE** (Ajustes → Inferencia y contexto, activado por defecto) sube el procesamiento del prompt de 1.8× a 4.4× adicional sobre ToshGEMM, sin costo en la generación, solapando la subida de pesos a la GPU con el cómputo. Disponible en ambos motores.
"""),
        DocSection(title: "Perfiles", icon: "person.2", body: """
Un perfil guarda **toda** la configuración: modelo, motor, parámetros de memoria y contexto. Se crean en Ajustes → Perfiles escribiendo un nombre y pulsando "Guardar actual".

Perfiles típicos:
- **Diario (MTP)**: modelo MTP + `--spec-type draft-mtp` en argumentos extra → máxima velocidad de chat
- **Contexto XL**: motor TurboQuant + claves `turbo4`/valores `turbo3` + contexto 64k → documentos largos

Al aplicar un perfil, reinicia el servidor para que tome efecto.
"""),
        DocSection(title: "Router: varios modelos sin reiniciar", icon: "arrow.triangle.2.circlepath", body: """
Activa **Router (multi-modelo)** en **Inicio → tarjeta del servidor → Opciones avanzadas** (no en Ajustes) para que un solo servidor sirva **todos** tus modelos descargados a la vez, sin necesidad de elegir uno fijo.

Cómo funciona: el servidor carga el modelo la primera vez que se pide (por su nombre) y lo deja en memoria; si pides otro, descarga el anterior y carga el nuevo automáticamente. **Modelos simultáneos** controla cuántos mantiene cargados a la vez (1 es lo más seguro con una sola GPU).

Dentro de la app, el chat muestra un selector de modelo (icono de caja) junto al campo de mensaje cuando el router está activo. Desde un cliente externo (VS Code, Continue…), simplemente indica el nombre del modelo en el campo `model` de la petición; la app deriva ese nombre del nombre del archivo .gguf (ej. `Qwen3.6-14B-A3B.gguf` → `qwen3-6-14b-a3b`), consultable en `GET /v1/models`.

Cada modelo conserva su propia configuración de expertos MoE, visión y MTP, calculada automáticamente. Disponible en ambos motores.
"""),
        DocSection(title: "MTP: generación acelerada", icon: "hare", body: """
**MTP (Multi-Token Prediction)** es una técnica donde el modelo predice varios tokens por pasada y luego los verifica — sin ninguna pérdida de calidad (solo acepta lo que habría generado de todas formas).

Última medición en este equipo: **+34% de velocidad de generación** (19.3 → 25.7 t/s en Qwen3.6-35B) con 82% de aceptación. Esa cifra es previa al fix de staging persistente, que ya subió el "sin MTP" de ~19 a ~25 t/s por sí solo. Falta remedir la ganancia real de MTP sobre el motor actual.

Para usarlo necesitas dos cosas:
1. Un GGUF con cabezal MTP (busca repos con "MTP" en el nombre, p. ej. `Qwen3.6-35B-A3B-MTP-GGUF` de unsloth — los GGUF normales no lo traen)
2. Agregar `--spec-type draft-mtp` en Ajustes → Avanzado → Argumentos extra

Funciona en ambos motores (Integrado y Experimental). El perfil "Diario (MTP)" ya lo configura todo. La ganancia depende mucho del modelo y del contenido generado: en algunos casos no acelera nada, o incluso sale un poco más lento. `llama-bench` no puede medirlo (no soporta el flag): compara siempre con generación real desde el chat o el servidor.
"""),
        DocSection(title: "API para desarrolladores", icon: "terminal", body: """
Con el servidor activo, tienes una **API compatible con OpenAI** en `http://127.0.0.1:8080` (puerto configurable). Funciona con cualquier librería o app que hable ese protocolo.

Por defecto solo responde en esta Mac. Para exponer la API local en la red, activa **Descubrible en red local** en Ajustes y reinicia el servidor. ToshLLM escuchará en todas las interfaces y anunciará `ToshLLM API` mediante Bonjour. Conecta usando `http://<IP-de-la-Mac>:8080/v1` y activa **Proteger la API con clave** antes de exponerla, especialmente fuera de una red confiable.

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

Ejemplo con Python (librería oficial `openai`, solo cambiando la URL base):

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8080/v1", api_key="no-hace-falta")
stream = client.chat.completions.create(
    model="local",  # ignorado salvo en modo Router, ver esa sección
    messages=[{"role": "user", "content": "Hola"}],
    stream=True,
)
for chunk in stream:
    print(chunk.choices[0].delta.content or "", end="")
```

**Streaming (SSE):** con `"stream": true`, cada línea llega como `data: {...}` con un delta incremental (`choices[0].delta.content`); el final se marca con `data: [DONE]`. Con modelos razonadores, el pensamiento llega en `delta.reasoning_content` (campo separado, no mezclado con `content`) salvo que actives "Razonamiento como texto" en Ajustes, que lo manda inline dentro de `content` entre etiquetas `<think>`.

Endpoints útiles:
- `POST /v1/chat/completions` — chat (streaming opcional)
- `POST /v1/completions` — completado de texto plano (sin plantilla de chat)
- `POST /v1/embeddings` — vectores de embedding, si activaste **Servidor de embeddings** (Inicio → tarjeta del servidor → Opciones avanzadas; usa un modelo dedicado a embeddings, no de chat)
- `GET /v1/models` — modelo(s) cargado(s) y capacidades anunciadas
- `POST /tokenize` / `POST /detokenize` — convierte texto ↔ ids de tokens del modelo activo
- `GET /health` — estado del servidor
- `GET /props` — metadatos del modelo (tamaño de contexto, plantilla de chat, etc.)

**Imágenes / visión:** carga un modelo con su `mmproj` y envía contenido OpenAI `image_url` (URL remota o `data:image/...;base64,...`). Los clientes configurables, como Raycast, también deben anunciar que el modelo admite visión. Usa como nombre de modelo el `id` devuelto por `/v1/models`. Cuando hay un `mmproj`, ToshLLM desactiva cache-reuse y la caché persistente de conversaciones porque `llama.cpp` no admite guardar/restaurar slots multimodales; la caché normal en memoria permanece activa.

También hay un chat web minimalista en la raíz (`http://127.0.0.1:8080`) para usar desde el navegador.

**Peticiones simultáneas:** el ajuste del mismo nombre (Ajustes → Inferencia y contexto) controla cuántas peticiones concurrentes acepta el servidor. En 1 (el valor por defecto), las peticiones se encolan una tras otra en vez de competir por la GPU, y una petición cortada por timeout retoma el procesamiento donde se quedó en el siguiente intento.

#### Conectar clientes externos

Cualquier cliente OpenAI-compatible (VS Code + Continue/Cline/Copilot con modelo propio, y en general casi todo lo demás):
- URL base: `http://127.0.0.1:8080/v1` · nombre de modelo: el `id` de `/v1/models` · clave API: la de Ajustes solo si activaste la protección.
- **Sube el Contexto a 32k o más**: estos clientes envían prompts enormes (instrucciones + archivos abiertos) y con 16k el servidor rechaza la petición. Compensa la memoria cuantizando las claves del KV cache a `q8_0`.
- Los modelos razonadores "piensan" antes de responder y muchos clientes no muestran esa fase: parece que **se quedó colgado** cuando en realidad está generando. Activa "Razonamiento como texto" en Ajustes → Inferencia, o usa un modelo no razonador para código.
- La **primera respuesta tarda**: en esta clase de GPU el prompt se procesa a ~80-120 t/s, así que 16k tokens son 2-4 minutos. **Limita los tokens de entrada del cliente** (p. ej. `maxInputTokens: 8000`) para que la primera petición baje a ~1-2 min; las siguientes reutilizan la caché y son incrementales.
- Si el cliente corta por timeout, reintenta: con "Peticiones simultáneas" en 1 (el valor por defecto), el reintento **retoma el procesamiento donde se quedó** en vez de empezar de cero.
- **¿Necesitas cambiar de modelo sin reiniciar el servidor?** Activa el modo Router (ver "Router: varios modelos sin reiniciar") y pon el nombre del modelo que quieras en cada petición.

##### OpenCode (CLI)
- Edita `~/.config/opencode/opencode.json` (o el `opencode.json` del proyecto) y agrega un proveedor con `"npm": "@ai-sdk/openai-compatible"` y `"options": {"baseURL": "http://127.0.0.1:8080/v1"}`.
- También puedes correr `/connect` dentro de OpenCode y elegir "Other".
- Reinicia OpenCode tras editar la config; los nombres de modelo deben coincidir exactamente con el `id` de `/v1/models`.

##### Google Antigravity
- Ajustes → Custom Models → añade uno con proveedor **OpenAI Compatible**.
- Endpoint: `http://127.0.0.1:8080/v1` · modelo: el `id` de `/v1/models`.

##### Cursor
- Ajustes (⌘,) → pestaña Models → sección OpenAI → activa **Override Base URL** y pega `http://127.0.0.1:8080/v1`.
- El campo de clave API no puede quedar vacío (pon cualquier texto si no protegiste la API).
- **Limitación real de Cursor, no de ToshLLM**: exige HTTPS para esa URL. Un endpoint local por HTTP simple no conecta directo, hace falta un proxy con TLS delante (p. ej. Caddy o un túnel tipo ngrok) apuntando a `127.0.0.1:8080`.

##### Raycast
- Ajustes → AI → Custom Providers.
- URL base: `http://127.0.0.1:8080/v1` · modelo: el `id` de `/v1/models`.
- Para imágenes, ver la nota de visión arriba.

##### Clientes de la API de Anthropic
Agentes de terminal y SDKs basados en el formato Anthropic, no solo OpenAI. El motor implementa también `/v1/messages` nativo, incluyendo streaming y llamadas a herramientas.
- La mayoría se redirigen con dos variables de entorno estándar del SDK: `ANTHROPIC_BASE_URL=http://127.0.0.1:8080` y `ANTHROPIC_AUTH_TOKEN=cualquier-texto` (o la clave real si activaste la protección).
- El servidor acepta tanto `Authorization: Bearer` como `x-api-key`, el header que usan estos clientes.
- Revisa la documentación de tu cliente para el nombre exacto de su archivo de configuración; muchos leen esas variables solo al arrancar, así que reinícialo tras cambiarlas.
"""),
        DocSection(title: "Rendimiento de referencia", icon: "gauge.high", body: """
Números medidos en el equipo de desarrollo (RX 6700 XT 12 GB, DDR4, macOS):

**Qwen3-8B Q4** (todo en VRAM, con ToshGEMM): ~312 t/s prompt, ~58 t/s generación

**Qwen3.6-35B-A3B Q4** (MoE híbrido, ncmoe 24):
- Normal: ~197 t/s prompt, ~25 t/s generación
- Con Prefetch de expertos MoE: ~470 t/s prompt (2.4×), generación sin cambio
- Con MTP: cifra sin remedir tras las mejoras de ToshGEMM/staging; la última medición (+34%, 19.3→25.7 t/s) es de antes de esos cambios y ya no es comparable contra el "Normal" de arriba
- Con TurboQuant (contexto XL): cifras de una versión anterior a ToshGEMM y al fix de staging persistente, pendientes de remedir

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

**Chat** — Conversations with the model: persistent history, multiple chats (⌘N), system prompt, regenerate responses, copy messages and code blocks, per-message speed, attach images (vision models) and text/PDF files (up to 40 MB, with automatic OCR for scanned PDFs).

**Models** — Local models detected in `~/models` (you can change the folder in Settings), curated catalog with memory estimates for your machine, Hugging Face search and downloads with progress. You can delete models (they go to Trash).

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
        DocSection(title: "Image generation", icon: "photo.on.rectangle.angled", body: """
The **Chat / Images** toggle at the top of the window switches to the image studio (beta, `stable-diffusion.cpp` engine on the same Metal stack).

**Catalog**: the app recommends a model based on your VRAM (Z-Image Turbo, Flux.2 klein, Flux.2 dev, Qwen-Image, SDXL Turbo…). Each one's badge shows whether it fits your GPU; there's a tolerance margin since macOS reports somewhat less usable VRAM than the card's physical amount.

**Main controls**: aspect ratio/size (snapped to the model's grid and capped by your VRAM), steps, CFG, seed (fix one to reproduce the same result) and output format. **Image to image**: upload a starting image and adjust Strength (low keeps the composition, high reinvents it). **Offload to CPU**: keeps weights in RAM and streams them to VRAM per stage, for large models on GPUs with limited memory (slower, but it fits).

**Parallel instances**: on Macs with several GPUs you can add extra instances, each with its own model, GPU and settings, and generate multiple variations at once from a single Generate button. Two instances on the same GPU show a warning (can hang the card on AMD GPUs).
"""),
        DocSection(title: "Parameters explained", icon: "slider.horizontal.3", body: """
**GPU layers (-ngl)** — How many layers go to VRAM. 99 = all (recommended). Any value above the model's layer count means "all".

**MoE experts on CPU** — See the MoE section.

**VRAM reserve** — Memory left free for the system. 1024 MB is safe.

**Copy weights to VRAM (--no-mmap)** — Essential on discrete GPUs: without it, weights are read over PCIe on every token and speed drops ~6×.

**Lock model in RAM (--mlock)** — Prevents macOS from swapping the model out. Useful with large MoE if you have spare RAM.

**Context** — Maximum conversation size in tokens. More context = more KV cache memory.

**KV cache keys/values (-ctk / -ctv)** — Quantization of attention memory. The best combo depends on whether you use the **AMD Flash Attention kernel**:
- **Without the kernel** (official engine): quantize keys only — `q8_0` (half the memory at near-zero cost, recommended) or `q4_0` (a quarter), keeping values at `f16`. Quantizing values too would force Flash Attention onto the CPU (~3× slower).
- **With the kernel** (Experimental + AMD Flash Attention): any standard combination (`f16`/`q8_0`/`q4_0` for keys and values) runs on the GPU at full speed. Maximum savings: `q8_0/q8_0` or `q4_0/q4_0`; compress only the keys while keeping value quality: `q8_0/f16` or `q4_0/f16`.

**Flash Attention** — Memory-efficient attention. `auto` is right on AMD GPUs.

**AMD dGPU stability** — Disables Metal concurrency. **Required**: without it, output corrupts on discrete AMD GPUs.

**CPU threads** — For the CPU-side work. Physical core count is usually optimal.
"""),
        DocSection(title: "Inference engines", icon: "engine.combustion", body: """
The app ships **two engines** and supports external ones (Settings → Advanced):

**Bundled (official)** — Official llama.cpp with AMD patches. Recommended for everything. Supports the newest architectures (Qwen 3.6, MTP).

**Experimental (TurboQuant)** — Engine with extreme KV cache quantization (`turbo2/3/4` types, based on compression research presented at ICLR 2026). Cuts context memory up to ~6×, enabling 100k+ token contexts on 12 GB GPUs. Cost: generation drops somewhat versus the same model with unquantized KV. Best measured combo: keys `turbo4` + values `turbo3`.

Selecting this engine reveals the **AMD Flash Attention kernel** toggle. It runs attention — both prompt processing and generation — on the AMD GPU via a custom Metal kernel (head dims 128, 256 and 512 — covers Gemma 4; KV types f16, q8_0, q4_0 in any keys/values combination, and turbo2/3/4). It matters most with quantized or turbo KV: those types **require** Flash Attention, so without the kernel attention falls back to the CPU and collapses with depth; with it everything stays on the GPU and generation holds up with depth (e.g. ~33 t/s at 4k context on an 8B).

**External** — Any `llama-server` binary of yours, for testing custom builds.

**ToshGEMM**, on by default on both engines, is a custom tiled matrix-multiply kernel for prompt processing on AMD GPUs; on this GPU it took an 8B's prompt speed from ~101 to ~312 t/s (~3×). It's not a toggle: it always runs when a model processes its prompt on the GPU.

For MoE models with experts in RAM (ncmoe > 0), the **MoE expert prefetch** toggle (Settings → Inference & context, on by default) raises prompt processing an additional 1.8×-4.4× on top of ToshGEMM, at no generation cost, by overlapping weight uploads to the GPU with compute. Available on both engines.
"""),
        DocSection(title: "Profiles", icon: "person.2", body: """
A profile saves **everything**: model, engine, memory and context parameters. Create them in Settings → Profiles by typing a name and pressing "Save current".

Typical profiles:
- **Daily (MTP)**: MTP model + `--spec-type draft-mtp` in extra arguments → fastest chat
- **Context XL**: TurboQuant engine + `turbo4` keys/`turbo3` values + 64k context → long documents

After applying a profile, restart the server for it to take effect.
"""),
        DocSection(title: "Router: multiple models, no restart", icon: "arrow.triangle.2.circlepath", body: """
Turn on **Router (multi-model)** in **Home → server card → Advanced options** (not in Settings) so one server serves **all** your downloaded models at once, with no need to pick a fixed one.

How it works: the server loads a model the first time it's requested (by name) and keeps it in memory; requesting a different one unloads the previous model and loads the new one automatically. **Models loaded at once** controls how many it keeps resident (1 is safest on a single GPU).

Inside the app, chat shows a model picker (box icon) next to the message field when the router is on. From an external client (VS Code, Continue…), just put the model's name in the request's `model` field; the app derives that name from the .gguf filename (e.g. `Qwen3.6-14B-A3B.gguf` → `qwen3-6-14b-a3b`), which you can check via `GET /v1/models`.

Each model keeps its own MoE experts, vision and MTP config, computed automatically. Available on both engines.
"""),
        DocSection(title: "MTP: faster generation", icon: "hare", body: """
**MTP (Multi-Token Prediction)** is a technique where the model predicts several tokens per pass and then verifies them — with zero quality loss (it only accepts what it would have generated anyway).

Last measurement on this machine: **+34% generation speed** (19.3 → 25.7 t/s on Qwen3.6-35B) with 82% acceptance. That figure predates the persistent-staging fix, which alone already raised the "without MTP" baseline from ~19 to ~25 t/s. MTP's real gain over the current engine still needs re-measuring.

You need two things:
1. A GGUF with the MTP head (look for repos with "MTP" in the name, e.g. unsloth's `Qwen3.6-35B-A3B-MTP-GGUF` — regular GGUFs don't include it)
2. Add `--spec-type draft-mtp` in Settings → Advanced → Extra arguments

Works on both engines (Bundled and Experimental). The "Daily (MTP)" profile configures everything. The gain depends heavily on the model and what it's generating: some cases see no speedup at all, or even a slight slowdown. `llama-bench` can't measure it (the flag isn't supported there): always compare using real generation from chat or the server.
"""),
        DocSection(title: "API for developers", icon: "terminal", body: """
With the server running, you get an **OpenAI-compatible API** at `http://127.0.0.1:8080` (configurable port). Works with any library or app that speaks the protocol.

By default it only accepts connections from this Mac. To expose the local API on the network, enable **Discoverable on local network** in Settings and restart the server. ToshLLM will listen on all interfaces and advertise `ToshLLM API` through Bonjour. Connect to `http://<Mac-IP>:8080/v1`, and enable **Protect the API with a key** before exposing it, especially outside a trusted network.

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

Example with Python (the official `openai` library, just pointing it at the local base URL):

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8080/v1", api_key="not-needed")
stream = client.chat.completions.create(
    model="local",  # ignored unless Router mode is on, see that section
    messages=[{"role": "user", "content": "Hello"}],
    stream=True,
)
for chunk in stream:
    print(chunk.choices[0].delta.content or "", end="")
```

**Streaming (SSE):** with `"stream": true`, each line arrives as `data: {...}` with an incremental delta (`choices[0].delta.content`); the end is marked by `data: [DONE]`. With reasoning models, thinking arrives in `delta.reasoning_content` (a separate field, never mixed into `content`) unless you enable "Reasoning as plain text" in Settings, which inlines it into `content` between `<think>` tags instead.

Useful endpoints:
- `POST /v1/chat/completions` — chat (optional streaming)
- `POST /v1/completions` — plain text completion (no chat template)
- `POST /v1/embeddings` — embedding vectors, if you enabled **Embeddings server** (Home → server card → Advanced options; use it with a dedicated embedding model, not a chat one)
- `GET /v1/models` — loaded model(s) and advertised capabilities
- `POST /tokenize` / `POST /detokenize` — convert text ↔ token ids for the active model
- `GET /health` — server status
- `GET /props` — model metadata (context size, chat template, etc.)

**Images / vision:** load a model with its `mmproj` and send OpenAI `image_url` content (a remote URL or `data:image/...;base64,...`). Configurable clients such as Raycast must also declare that the model supports vision. Use the model `id` returned by `/v1/models`. While an `mmproj` is loaded, ToshLLM disables cache-reuse and persistent conversation caching because `llama.cpp` cannot save/restore multimodal slots; normal in-memory prompt caching remains enabled.

There's also a minimal web chat at the root (`http://127.0.0.1:8080`) for browser use.

**Concurrent requests:** the setting of the same name (Settings → Inference & context) controls how many concurrent requests the server accepts. At 1 (the default), requests queue instead of competing for the GPU, and a request cut off by a timeout resumes processing where it stopped on the next attempt.

#### Connecting external clients

Any OpenAI-compatible client (VS Code + Continue/Cline/Copilot with a custom model, and generally almost everything else):
- Base URL: `http://127.0.0.1:8080/v1` · model name: the `id` from `/v1/models` · API key: the one in Settings only if you enabled protection.
- **Raise Context to 32k or more**: these clients send huge prompts (instructions + open files) and at 16k the server rejects the request. Offset the memory by quantizing KV cache keys to `q8_0`.
- Reasoning models "think" before answering and many clients don't display that phase: it **looks hung** while it's actually generating. Enable "Reasoning as plain text" in Settings → Inference, or use a non-reasoning model for coding.
- The **first response takes a while**: on this class of GPU prompts process at ~80-120 t/s, so 16k tokens take 2-4 minutes. **Limit the client's input tokens** (e.g. `maxInputTokens: 8000`) so the first request drops to ~1-2 min; later ones reuse the cache and are incremental.
- If the client times out, retry: with "Concurrent requests" at 1 (the default), the retry **resumes processing where it stopped** instead of starting over.
- **Need to switch models without restarting the server?** Turn on Router mode (see "Router: multiple models, no restart") and put whichever model name you want in each request.

##### OpenCode (CLI)
- Edit `~/.config/opencode/opencode.json` (or the project's `opencode.json`) and add a provider with `"npm": "@ai-sdk/openai-compatible"` and `"options": {"baseURL": "http://127.0.0.1:8080/v1"}`.
- You can also run `/connect` inside OpenCode and pick "Other".
- Restart OpenCode after editing the config; model names must match the `id` from `/v1/models` exactly.

##### Google Antigravity
- Settings → Custom Models → add one with provider **OpenAI Compatible**.
- Endpoint: `http://127.0.0.1:8080/v1` · model: the `id` from `/v1/models`.

##### Cursor
- Settings (⌘,) → Models tab → OpenAI section → enable **Override Base URL** and paste `http://127.0.0.1:8080/v1`.
- The API key field can't be empty (type anything if you didn't protect the API).
- **A real Cursor limitation, not ToshLLM's**: it requires HTTPS for that URL. A plain local HTTP endpoint won't connect directly, you'll need a TLS proxy in front (e.g. Caddy or an ngrok-style tunnel) pointing at `127.0.0.1:8080`.

##### Raycast
- Settings → AI → Custom Providers.
- Base URL: `http://127.0.0.1:8080/v1` · model: the `id` from `/v1/models`.
- For images, see the vision note above.

##### Anthropic API clients
Terminal agents and SDKs built on the Anthropic format, not just OpenAI's. The engine also implements native `/v1/messages`, including streaming and tool calls.
- Most of these clients redirect via two standard SDK environment variables: `ANTHROPIC_BASE_URL=http://127.0.0.1:8080` and `ANTHROPIC_AUTH_TOKEN=any-text` (or the real key if you enabled protection).
- The server accepts both `Authorization: Bearer` and `x-api-key`, the header these clients use.
- Check your client's docs for its exact config file name; many only read those variables at startup, so restart it after changing them.
"""),
        DocSection(title: "Reference performance", icon: "gauge.high", body: """
Numbers measured on the development machine (RX 6700 XT 12 GB, DDR4, macOS):

**Qwen3-8B Q4** (fully in VRAM, with ToshGEMM): ~312 t/s prompt, ~58 t/s generation

**Qwen3.6-35B-A3B Q4** (hybrid MoE, ncmoe 24):
- Normal: ~197 t/s prompt, ~25 t/s generation
- With MoE expert prefetch: ~470 t/s prompt (2.4×), generation unchanged
- With MTP: not re-measured since the ToshGEMM/staging fixes; the last measurement (+34%, 19.3→25.7 t/s) predates those and isn't comparable to the "Normal" line above anymore
- With TurboQuant (XL context): figures predate ToshGEMM and the persistent-staging fix, pending re-measurement

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
