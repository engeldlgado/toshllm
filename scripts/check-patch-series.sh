#!/bin/zsh
# Dry-runs the whole llama.cpp patch series against an upstream ref and reports what
# applies and what does not. Unlike build-engines.sh it never stops at the first failure:
# a bump is worth judging by how much of the series moved, not by which patch broke first.
#
#   ./scripts/check-patch-series.sh                 # against upstream HEAD
#   ./scripts/check-patch-series.sh <ref>           # against a specific commit
#   ./scripts/check-patch-series.sh <ref> out.md    # also write the report as Markdown
#
# Exit 0 when every patch applies (cleanly or with a three-way merge), 1 otherwise.
set -u
cd "$(dirname "$0")/.."
ROOT="$PWD"

REF="${1:-origin/master}"
REPORT="${2:-}"

PIN="$(grep -oE 'LLAMA_COMMIT:-[a-f0-9]+' scripts/build-engines.sh | cut -d- -f2)"

# Work off the vendor clone when it exists (it already has the objects); otherwise make a
# throwaway blobless clone. Either way the check runs in its own worktree and never touches
# a tree someone may be building in.
VENDOR="$ROOT/vendor/llama.cpp"
TMP="$(mktemp -d)"
cleanup() {
    git -C "$VENDOR" worktree remove --force "$TMP/tree" 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT

if [ ! -d "$VENDOR/.git" ]; then
    git clone -q --filter=blob:none https://github.com/ggml-org/llama.cpp "$TMP/clone" || exit 1
    VENDOR="$TMP/clone"
fi
git -C "$VENDOR" fetch -q origin "${REF#origin/}" 2>/dev/null || git -C "$VENDOR" fetch -q origin
git -C "$VENDOR" worktree add -q --detach "$TMP/tree" "$REF" || {
    echo "cannot check out $REF" >&2; exit 1
}
TREE="$TMP/tree"
HEAD_SHA="$(git -C "$TREE" rev-parse --short HEAD)"

typeset -a rows failed_files
ok=0; threeway=0; bad=0; rejected_hunks=0

for patch in "$ROOT"/patches/llama/*.patch; do
    name="${patch:t}"
    if git -C "$TREE" apply "$patch" 2>/dev/null; then
        rows+=("OK|$name|")
        ok=$((ok+1))
        continue
    fi
    if git -C "$TREE" apply --3way "$patch" 2>/dev/null; then
        rows+=("3WAY|$name|resolved by three-way merge")
        threeway=$((threeway+1))
        continue
    fi
    # Keep going: apply what lands and count what does not, so the report covers the whole
    # series instead of ending at the first break.
    git -C "$TREE" apply --reject "$patch" >/dev/null 2>&1
    local_rej=$(find "$TREE" -name '*.rej' | wc -l | tr -d ' ')
    files=$(find "$TREE" -name '*.rej' -exec basename {} .rej \; | sort -u | tr '\n' ' ')
    find "$TREE" \( -name '*.rej' -o -name '*.orig' \) -delete
    rows+=("FAIL|$name|$local_rej hunk(s) rejected in ${files:-unknown}")
    failed_files+=(${=files})
    bad=$((bad+1))
    rejected_hunks=$((rejected_hunks+local_rej))
done

total=$((ok+threeway+bad))

emit() {
    print -r -- "$1"
    [ -n "$REPORT" ] && print -r -- "$1" >> "$REPORT"
}
[ -n "$REPORT" ] && : > "$REPORT"

emit "## Patch series against llama.cpp \`$HEAD_SHA\`"
emit ""
emit "Pinned commit today: \`$PIN\`."
emit ""
emit "| | Patch | Note |"
emit "|---|---|---|"
for r in "${rows[@]}"; do
    st="${r%%|*}"; rest="${r#*|}"; nm="${rest%%|*}"; note="${rest#*|}"
    case "$st" in
        OK)   mark="clean" ;;
        3WAY) mark="three-way" ;;
        *)    mark="**FAILS**" ;;
    esac
    emit "| $mark | \`$nm\` | $note |"
done
emit ""
emit "**$ok of $total apply cleanly**, $threeway need a three-way merge, $bad fail ($rejected_hunks hunks rejected)."

if [ "$bad" -gt 0 ]; then
    emit ""
    emit "### What moved underneath them"
    emit ""
    typeset -A seen
    for f in "${failed_files[@]}"; do
        [ -n "${seen[$f]:-}" ] && continue
        seen[$f]=1
        relpath=$(git -C "$TREE" ls-files "**/$f" | head -1)
        [ -z "$relpath" ] && continue
        emit "\`$relpath\`:"
        emit ""
        git -C "$VENDOR" log --oneline "$PIN..$HEAD_SHA" -- "$relpath" 2>/dev/null |
            while read -r line; do emit "- $line"; done
        emit ""
    done
fi

[ "$bad" -gt 0 ] && exit 1
exit 0
