#!/usr/bin/env bash
# Hot reload for the main window: opens it on sample keymap data, no keyboard
# needed, and rebuilds and relaunches on every save under Sources/, back on
# the pane that was showing.
exec env DEV_FLAG=--ui-dev "$(dirname "$0")/hud-dev.sh" "$@"
