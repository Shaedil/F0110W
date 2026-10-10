#!/usr/bin/env bash
# Installs (or removes) a LaunchAgent so the HUD starts at login.
#   ./install-agent.sh [--uninstall]
set -euo pipefail

cd "$(dirname "$0")"

LABEL="com.shaedil.m0110hud"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
# Use the installed copy, because an agent that points into a working tree
# breaks when the tree moves.
APP="/Applications/M0110HUD.app"
BIN="${APP}/Contents/MacOS/M0110HUD"

if [[ "${1:-}" == "--uninstall" ]]; then
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Removed ${PLIST}"
    exit 0
fi

if [[ ! -x "$BIN" ]]; then
    echo "error: ${BIN} not found; run ./build.sh first" >&2
    exit 1
fi

mkdir -p "$(dirname "$PLIST")"

{
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    printf '%s\n' '<plist version="1.0">'
    printf '%s\n' '<dict>'
    printf '\t%s\n' '<key>Label</key>'
    printf '\t%s\n' "<string>${LABEL}</string>"
    printf '\t%s\n' '<key>ProgramArguments</key>'
    printf '\t%s\n' '<array>'
    printf '\t\t%s\n' "<string>${BIN}</string>"
    printf '\t\t%s\n' '<string>--no-initial</string>'
    printf '\t%s\n' '</array>'
    printf '\t%s\n' '<key>RunAtLoad</key>'
    printf '\t%s\n' '<true/>'
    printf '\t%s\n' '<key>KeepAlive</key>'
    printf '\t%s\n' '<true/>'
    printf '\t%s\n' '<key>ProcessType</key>'
    printf '\t%s\n' '<string>Interactive</string>'
    printf '%s\n' '</dict>'
    printf '%s\n' '</plist>'
} > "$PLIST"

# bootout first so a re-run picks up path or argument changes.
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
# If the label is in launchd's disabled list, bootstrap fails with only
# "Input/output error", so enable it first.
launchctl enable "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "Installed ${PLIST}"
launchctl print "gui/$(id -u)/${LABEL}" 2>/dev/null | grep -E "^\s+(state|pid) " | sed 's/^/    /' || true
echo
echo "The agent runs ${APP}, which build.sh keeps up to date."
echo "It starts at login and on wake, lives in the menu bar with no Dock icon,"
echo "and KeepAlive restarts it if it ever exits."
