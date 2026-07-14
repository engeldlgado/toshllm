#!/bin/zsh
# One-shot release: stamps the CHANGELOG section for the current VERSION,
# commits the bump if needed, tags and pushes. CI publishes the DMG from
# the tag and takes the release body from that CHANGELOG section.
set -e
cd "$(dirname "$0")/.."

V="$(cat VERSION)"

if git rev-parse -q --verify "refs/tags/v$V" > /dev/null; then
    echo "tag v$V already exists; bump VERSION (./make-app.sh) first" >&2
    exit 1
fi

if grep -q '^## \[Unreleased\]' CHANGELOG.md; then
    sed -i '' "s/^## \[Unreleased\]/## [$V] - $(date +%F)/" CHANGELOG.md
fi
if ! grep -q "^## \[$V\]" CHANGELOG.md; then
    echo "CHANGELOG.md has no '## [$V]' section and no '## [Unreleased]' to stamp" >&2
    exit 1
fi

git add CHANGELOG.md VERSION Sources/AboutTab.swift
git diff --cached --quiet || git commit -m "release: $V"

git tag "v$V"
git push origin main "v$V"
echo "released v$V"
