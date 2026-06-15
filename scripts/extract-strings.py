#!/usr/bin/env python3
"""Extract translatable UI strings from the Swift sources.

Scans every `Sources/**/*.swift` file for `t("es", "en")` calls (the bilingual
helper, including `loc.t(...)`) and writes the set of **English** strings — the
keys community overlays use — to `Assets/lang/_template.json` as a flat
`{ "English string": "" }` map.

Translators copy the template to `Assets/lang/<code>.json` (e.g. `it.json`) and
fill in the values. Missing or blank values fall back to English at runtime, so
a partial translation is always safe. Strings built with interpolation
(`\\(...)`) are skipped: their runtime value is dynamic and can't be matched by
an exact-string overlay (they stay English in other languages).

Usage:  python3 scripts/extract-strings.py
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"
OUT = ROOT / "Assets" / "lang" / "_template.json"

# t( "<swift string>" , "<swift string>" )  — both literals, across newlines.
# A Swift string body is any run of non-quote / non-backslash chars or escapes.
STR = r'"((?:[^"\\]|\\.)*)"'
CALL = re.compile(r'\bt\(\s*' + STR + r'\s*,\s*' + STR + r'\s*\)', re.DOTALL)

# Strings used by the standalone web console (Assets/test-ui/index.html). They
# don't live in Swift, so they're listed here to appear in the template; the
# page loads the same lang/<code>.json overlays keyed by these English texts.
WEB_STRINGS = [
    "Max tokens", "Clear chat", "Send", "Stop",
    "Type your message… (Enter sends, Shift+Enter newline)",
    "Reasoning", "You", "Assistant",
    "connecting…", "unknown model", "server unavailable",
    "first resp.", "is llama-server running?",
]

# Minimal Swift -> literal unescaping for the characters that actually appear in
# UI strings; the JSON writer re-escapes on output.
UNESCAPE = {'\\"': '"', '\\\\': '\\', '\\n': '\n', '\\t': '\t'}


def unescape(s: str) -> str:
    return re.sub(r'\\["\\nt]', lambda m: UNESCAPE[m.group(0)], s)


def main() -> int:
    keys: set[str] = set()
    for path in SOURCES.rglob("*.swift"):
        text = path.read_text(encoding="utf-8")
        for _es, en in CALL.findall(text):
            if r'\(' in en:        # interpolated -> not statically translatable
                continue
            keys.add(unescape(en))

    keys.update(WEB_STRINGS)
    template = {k: "" for k in sorted(keys)}
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(template, ensure_ascii=False, indent=2) + "\n",
                   encoding="utf-8")
    print(f"Wrote {len(template)} keys to {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
