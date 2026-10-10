#!/usr/bin/env bash
# Hot reload for the main window, using sample keymap data so no keyboard is needed.
exec env DEV_FLAG=--ui-dev "$(dirname "$0")/hud-dev.sh" "$@"
