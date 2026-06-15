#!/usr/bin/env python3
"""Update the language status table in Assets/lang/README.md.

For every language it counts how many of the template strings are filled in and
writes the result as a table between the STATUS markers in the README. Run it
after adding or editing a translation, or after regenerating the template:

    python3 scripts/translation-status.py
"""

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LANG = ROOT / "Assets" / "lang"
TEMPLATE = LANG / "_template.json"
README = LANG / "README.md"

# Popular languages shown in the table even before anyone starts them, so
# contributors can see what is wanted. (code, English name, native name)
FEATURED = [
    ("es", "Spanish", "Español"),
    ("en", "English", "English"),
    ("it", "Italian", "Italiano"),
    ("de", "German", "Deutsch"),
    ("fr", "French", "Français"),
    ("pt", "Portuguese", "Português"),
    ("zh", "Chinese (Simplified)", "简体中文"),
    ("ja", "Japanese", "日本語"),
    ("ko", "Korean", "한국어"),
    ("ru", "Russian", "Русский"),
    ("hi", "Hindi", "हिन्दी"),
    ("tr", "Turkish", "Türkçe"),
    ("nl", "Dutch", "Nederlands"),
    ("pl", "Polish", "Polski"),
]

MARK_START = "<!-- STATUS:START -->"
MARK_END = "<!-- STATUS:END -->"


def filled(code: str, keys: list[str]) -> int:
    """Number of template strings the language file translates (non-empty)."""
    path = LANG / f"{code}.json"
    if not path.exists():
        return 0
    data = json.loads(path.read_text(encoding="utf-8"))
    return sum(1 for k in keys if data.get(k, "").strip())


def main() -> None:
    keys = list(json.loads(TEMPLATE.read_text(encoding="utf-8")))
    total = len(keys)

    featured_codes = {c for c, _, _ in FEATURED}
    rows = list(FEATURED)
    # Any language file that is not already featured.
    for path in sorted(LANG.glob("*.json")):
        code = path.stem
        if not code.startswith("_") and code not in featured_codes:
            rows.append((code, code.upper(), code))

    lines = ["| Language | Code | Status |", "|---|---|---|"]
    for code, en_name, native in rows:
        if code in ("es", "en"):
            status = "Built-in (100%)"
        else:
            done = filled(code, keys)
            pct = round(done * 100 / total) if total else 0
            status = "not started" if done == 0 else f"{pct}% ({done}/{total})"
        lines.append(f"| {en_name} ({native}) | `{code}` | {status} |")
    table = "\n".join(lines)

    block = f"{MARK_START}\n\n{table}\n\n{MARK_END}"
    text = README.read_text(encoding="utf-8")
    text = re.sub(re.escape(MARK_START) + r".*?" + re.escape(MARK_END),
                  block, text, flags=re.DOTALL)
    README.write_text(text, encoding="utf-8")
    print(f"Updated status table for {len(rows)} languages ({total} strings).")


if __name__ == "__main__":
    main()
