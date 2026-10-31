#!/bin/bash
# Runs the model-level self-test and the UI test against build/File Explorer.app.
# Build first with ./build.sh. The UI test drives a real window with synthetic
# clicks and keystrokes (about 30 s); you can keep working in other apps meanwhile.
#
#   ./test.sh            both suites
#   ./test.sh ui         UI test only
#   ./test.sh self       self-test only
#   SHOTS=dir ./test.sh ui   also save light/dark screenshots of key states to dir
cd "$(dirname "$0")"

BIN="build/File Explorer.app/Contents/MacOS/FileExplorer"
[ -x "$BIN" ] || { echo "Build first: ./build.sh"; exit 1; }

run() {  # <label> <env assignments...>
    local label=$1; shift
    echo "==> $label"
    env "$@" WINEXP_NORECENTS=1 "$BIN" 2>/dev/null | grep -E "^  (PASS|FAIL)|passed,"
    return "${PIPESTATUS[0]}"
}

status=0
if [ "$1" != "ui" ]; then
    run "Self-test" WINEXP_SELFTEST=1 || status=1
fi
if [ "$1" != "self" ]; then
    run "UI test" WINEXP_UITEST=1 ${SHOTS:+"WINEXP_UITEST_SHOTS=$SHOTS"} || status=1
fi
exit $status
