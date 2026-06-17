#!/bin/zsh
# Runs the unit tests locally. The Command Line Tools don't ship XCTest, so we
# point DEVELOPER_DIR at Xcode.app for this invocation only — no global
# xcode-select change, nothing else on the machine is affected. Extra args are
# forwarded to swift test (e.g. ./scripts/test.sh --filter ServerSettingsTests).
set -e
cd "$(dirname "$0")/.."

DEV="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [ ! -d "$DEV" ]; then
    echo "Xcode not found at $DEV — install Xcode (CLT alone lacks XCTest), or set DEVELOPER_DIR." >&2
    exit 1
fi

DEVELOPER_DIR="$DEV" swift test "$@"
