#!/usr/bin/env python3
"""Sync community translation files to the template.

Rewrites every `Assets/lang/<code>.json` so it holds exactly the template's
keys, in the template's order: existing translations are kept, strings missing
from a language are added as "" (empty), and keys no longer in the template are
dropped. The empty entries make it obvious — right inside the file — what still
needs translating, so a contributor sees the full to-do list without having to
diff against the template. Untranslated strings fall back to English at runtime
regardless, so an incomplete file never breaks the interface.

    python3 scripts/sync-translations.py          # rewrite the files in place
    python3 scripts/sync-translations.py --check   # exit 1 if any file is out of sync
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LANG = ROOT / "Assets" / "lang"
TEMPLATE = LANG / "_template.json"


def render(existing: dict, template_keys: list) -> str:
    synced = {k: existing.get(k, "") for k in template_keys}
    return json.dumps(synced, ensure_ascii=False, indent=2) + "\n"


def main() -> int:
    template_keys = list(json.loads(TEMPLATE.read_text(encoding="utf-8")))
    check = "--check" in sys.argv
    drift = False

    for path in sorted(LANG.glob("*.json")):
        if path.stem.startswith("_"):
            continue
        current = path.read_text(encoding="utf-8")
        try:
            existing = json.loads(current)
        except json.JSONDecodeError as e:
            print(f"{path.name}: invalid JSON — {e}")
            drift = True
            continue
        wanted = render(existing, template_keys)
        if current == wanted:
            continue
        if check:
            print(f"{path.name}: out of sync with the template")
            drift = True
        else:
            path.write_text(wanted, encoding="utf-8")
            data = json.loads(wanted)
            empty = sum(1 for v in data.values() if not v)
            print(f"{path.name}: synced — {len(data)} keys, {empty} still empty")

    if check and drift:
        print("Run: python3 scripts/sync-translations.py")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
