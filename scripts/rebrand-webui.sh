#!/bin/zsh
# Builds the llama.cpp web UI (MIT) from vendor, with ToshLLM's patches (patches/llama/ui),
# and rebrands it into Assets/web-ui, served with --path. A built dist can be given instead.
# Only user-visible strings change; wire identifiers and storage keys are left alone.
# A substitution that stops matching is a hard error, not a silent pass-through.
set -e

ROOT="${0:a:h:h}"
OUT="$ROOT/Assets/web-ui"
if [ -n "$1" ]; then
    SRC="$1"
else
    SRC="$(mktemp -d)/dist"
    (cd "$ROOT/vendor/llama.cpp/tools/ui" && npm ci --no-audit --no-fund && LLAMA_UI_OUT_DIR="$SRC" npm run build)
fi

[ -f "$SRC/index.html" ] || { echo "no web UI assets at $SRC (build the engine first)"; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"
# _gzip is the pre-compressed copy for the embedded server; --path wants plain files
(cd "$SRC" && tar cf - --exclude=_gzip .) | (cd "$OUT" && tar xf -)

bundle=$(find "$OUT/_app" -name 'bundle.*.js' | head -1)
[ -n "$bundle" ] || { echo "no bundle.*.js under $OUT/_app"; exit 1; }

python3 - "$bundle" "$OUT/manifest.webmanifest" "$OUT/index.html" <<'PY'
import json, sys

bundle, manifest, index = sys.argv[1], sys.argv[2], sys.argv[3]

# `llama-ui` is the app name the document title interpolates; the other is the one
# hardcoded title in the bundle.
subs = [
    ('VITE_PUBLIC_APP_NAME||"llama-ui"', 'VITE_PUBLIC_APP_NAME||"ToshLLM"'),
    ('"Search · llama.cpp"',             '"Search · ToshLLM"'),
    ('`llama_settings_${',               '`toshllm_settings_${'),
]
src = open(bundle, encoding="utf-8").read()
for old, new in subs:
    if old not in src:
        raise SystemExit(f"rebrand: pattern not found in bundle: {old}")
    src = src.replace(old, new)
open(bundle, "w", encoding="utf-8").write(src)

m = json.load(open(manifest, encoding="utf-8"))
m["name"] = m["short_name"] = "ToshLLM"
m["description"] = "Local AI chat interface. llama.cpp web UI, rebranded for ToshLLM."
json.dump(m, open(manifest, "w", encoding="utf-8"), ensure_ascii=False, separators=(",", ":"))

# The UI is upstream's work, so credit it where a user can see it.
badge = """<style>
#tosh-upstream-credit{position:fixed;right:8px;bottom:6px;z-index:2147483647;
 font:11px/1.4 -apple-system,BlinkMacSystemFont,sans-serif;opacity:.45;
 color:currentColor;text-decoration:none;pointer-events:auto}
#tosh-upstream-credit:hover{opacity:.9}
@media (max-width:640px){#tosh-upstream-credit{display:none}}
</style>
<a id="tosh-upstream-credit" href="https://github.com/ggml-org/llama.cpp" target="_blank"
   rel="noopener">llama.cpp web UI (MIT), rebranded for ToshLLM</a>
"""
html = open(index, encoding="utf-8").read()
if "tosh-upstream-credit" not in html:
    if "</body>" not in html:
        raise SystemExit("rebrand: no </body> in index.html")
    html = html.replace("</body>", badge + "</body>", 1)
open(index, "w", encoding="utf-8").write(html)
PY

# App icon: our art under the filenames the bundle swaps at runtime (it picks
# ico/svg by theme). The iOS splash screens carry upstream's logo and only matter
# for "add to home screen", so they go, and the service worker manifest is rebuilt
# to match: a stale precache is what keeps serving the old icon.
ICON="$ROOT/icon-1024.png"
if [ -f "$ICON" ]; then
    for spec in "apple-touch-icon-180x180.png 180" "pwa-64x64.png 64" "pwa-192x192.png 192" \
                "pwa-512x512.png 512" "maskable-icon-512x512.png 512"; do
        set -- ${=spec}
        sips -s format png -z "$2" "$2" "$ICON" --out "$OUT/$1" >/dev/null
    done
    sips -s format png -z 48 48   "$ICON" --out "$OUT/.ico48.png"  >/dev/null
    sips -s format png -z 512 512 "$ICON" --out "$OUT/.icon512.png" >/dev/null
    rm -f "$OUT"/apple-splash-*.png
    GLYPH="$ROOT/AppIcon.icon/Assets/glyph.png"
    sips -s format png -z 256 256 "${GLYPH:-$ICON}" --out "$OUT/.icon256.png" >/dev/null
    python3 - "$OUT" <<'PYICON'
import base64, glob, hashlib, os, re, struct, sys, zlib
out = sys.argv[1]

png48  = open(os.path.join(out, ".ico48.png"), "rb").read()
png512 = open(os.path.join(out, ".icon512.png"), "rb").read()

# ICO container around a PNG frame (browsers have read PNG-in-ICO since Vista)
ico = struct.pack("<HHH", 0, 1, 1) + struct.pack("<BBBBHHII", 48, 48, 0, 0, 1, 32, len(png48), 22) + png48
svg = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">'
       '<image width="512" height="512" href="data:image/png;base64,'
       + base64.b64encode(png512).decode() + '"/></svg>').encode()

for name, blob in [("favicon.ico", ico), ("favicon-dark.ico", ico),
                   ("favicon.svg", svg), ("favicon-dark.svg", svg)]:
    open(os.path.join(out, name), "wb").write(blob)
for tmp in (".ico48.png", ".icon512.png"):
    os.remove(os.path.join(out, tmp))

index = os.path.join(out, "index.html")
html = open(index, encoding="utf-8").read()
html = re.sub(r'\s*<link[^>]*rel="apple-touch-startup-image"[^>]*>', '', html)
open(index, "w", encoding="utf-8").write(html)

# The sidebar mark is upstream's logo inlined in the bundle as a template literal.
png256 = open(os.path.join(out, ".icon256.png"), "rb").read()
os.remove(os.path.join(out, ".icon256.png"))
bundle = glob.glob(os.path.join(out, "_app", "immutable", "bundle.*.js"))[0]
js = open(bundle, encoding="utf-8").read()
# llama-brand draws it on a 600 box, the older in-tree logo on 512
m = re.search(r'`<svg width="(\d+)" height="\1" viewBox="0 0 \1 \1" fill="none".*?</svg>\s*`', js, re.S)
if not m:
    raise SystemExit("rebrand: inline logo svg not found in bundle")
# the glyph asset is padded like an app icon, so crop to its opaque box and scale it
# to the same optical size upstream's mark had, then paint it with currentColor
def alpha_box(png):
    pos, idat, w, h = 8, b"", 0, 0
    while pos < len(png):
        ln = struct.unpack(">I", png[pos:pos + 4])[0]
        typ, data = png[pos + 4:pos + 8], png[pos + 8:pos + 8 + ln]
        if typ == b"IHDR":
            w, h = struct.unpack(">II", data[:8])
        elif typ == b"IDAT":
            idat += data
        pos += 12 + ln
    bpp = 4
    raw, prev, i, rows = zlib.decompress(idat), bytearray(w * bpp), 0, []
    for _ in range(h):
        f = raw[i]; i += 1
        line = bytearray(raw[i:i + w * bpp]); i += w * bpp
        for x in range(len(line)):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(bytes(line)); prev = line
    xs = [x for y in range(h) for x in range(w) if rows[y][x * 4 + 3] > 16]
    ys = [y for y in range(h) for x in range(w) if rows[y][x * 4 + 3] > 16]
    return w, h, min(xs), min(ys), max(xs) - min(xs) + 1, max(ys) - min(ys) + 1

sw_px, sh_px, bx, by, bw, bh = alpha_box(png256)
target = 502.0
k = target / max(bw, bh)
ix = (512 - bw * k) / 2 - bx * k
iy = (512 - bh * k) / 2 - by * k
ours = ('`<svg width="512" height="512" viewBox="0 0 512 512" xmlns="http://www.w3.org/2000/svg">'
        '<defs><mask id="toshGlyphMask">'
        f'<image x="{ix:.1f}" y="{iy:.1f}" width="{sw_px * k:.1f}" height="{sh_px * k:.1f}" '
        'href="data:image/png;base64,' + base64.b64encode(png256).decode() + '"/>'
        '</mask></defs>'
        '<rect width="512" height="512" fill="currentColor" mask="url(#toshGlyphMask)"/></svg>`')
open(bundle, "w", encoding="utf-8").write(js[:m.start()] + ours + js[m.end():])

sw = os.path.join(out, "sw.js")
if os.path.exists(sw):
    src = open(sw, encoding="utf-8").read()
    kept = dropped = 0
    def fix(m):
        global kept, dropped
        url = m.group(1)
        rel = url.split("?")[0]
        # the navigation entry ("./") stands for index.html
        path = os.path.join(out, "index.html" if rel in ("./", "/", "") else rel)
        if not os.path.isfile(path):
            dropped += 1
            return ""
        kept += 1
        rev = hashlib.md5(open(path, "rb").read()).hexdigest()
        return '{url:"%s",revision:"%s"},' % (url, rev)
    src = re.sub(r'\{url:"([^"]+)",revision:"[^"]*"\},?', fix, src)
    src = src.replace(",]", "]")
    open(sw, "w", encoding="utf-8").write(src)
    print(f"  service worker: {kept} entradas revalidadas, {dropped} obsoletas fuera")
PYICON
else
    echo "WARNING: icon-1024.png missing; keeping upstream art"
fi

echo "web UI rebranded into ${OUT#$ROOT/} ($(du -sh "$OUT" | cut -f1))"
