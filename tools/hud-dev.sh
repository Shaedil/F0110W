#!/usr/bin/env bash
# Hot reload for the HUD: runs the debug panel, and rebuilds and relaunches it
# whenever anything under Sources/ changes. The panel restores its settings and
# reshows the last HUD at launch, so each save lands with the change on screen.
#
# Extra arguments are passed through to the app, e.g.:
#   tools/hud-dev.sh --verbose
set -uo pipefail

cd "$(dirname "$0")/.."

command -v fswatch >/dev/null || { echo "needs fswatch: brew install fswatch" >&2; exit 1; }

BIN="$(swift build --show-bin-path)/M0110HUD"
pid=""

stop() {
    [[ -n "$pid" ]] || return 0
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    pid=""
}

rebuild() {
    printf '\n==> building (%s)\n' "$(date +%H:%M:%S)"
    # Debug configuration: incremental builds are seconds, not a release link.
    if out="$(swift build 2>&1)"; then
        echo "$out" | grep -E "warning:" || true
        stop
        "$BIN" "${DEV_FLAG:---debug}" "$@" &
        pid=$!
        echo "==> running (pid $pid)"
    else
        echo "$out" | grep -E "error:|^\s" | head -60
        echo "==> build failed; the previous copy keeps running"
    fi
}

trap 'stop; exit 0' INT TERM EXIT

rebuild "$@"
# -o: one line per batch of changes, so a save that touches several files (or
# an editor's write-then-rename) triggers one build, not several.
while read -r _; do
    rebuild "$@"
done < <(fswatch -o -l 0.3 --exclude '\.swp$' --exclude '~$' Sources)
