#!/usr/bin/env python3
"""Validate community translation files.

Checks every `Assets/lang/<code>.json`:
  - it parses as JSON and is an object,
  - it has no keys that are absent from the template (a typo or a string that no
    longer exists; such keys are dead weight that never matches at runtime).

Exits non-zero on any problem so the pre-commit hook can block the commit.

    python3 scripts/check-translations.py
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LANG = ROOT / "Assets" / "lang"
TEMPLATE = LANG / "_template.json"


def main() -> int:
    keys = set(json.loads(TEMPLATE.read_text(encoding="utf-8")))
    ok = True

    for path in sorted(LANG.glob("*.json")):
        if path.stem.startswith("_"):
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as e:
            print(f"{path.name}: invalid JSON — {e}")
            ok = False
            continue
        if not isinstance(data, dict):
            print(f"{path.name}: the file must be a JSON object")
            ok = False
            continue
        stale = [k for k in data if k not in keys]
        if stale:
            ok = False
            print(f"{path.name}: {len(stale)} key(s) not found in the template "
                  f"(typo, or the string was removed):")
            for k in stale[:10]:
                print(f"    {k!r}")

    if not ok:
        print("Translation check failed.")
        return 1
    print("Translation files OK.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
