#!/usr/bin/env bash
# Draws the Windows HUD and tray icon to a PNG on a Mac. HUDRaster.swift draws in
# software, so it matches Windows except that Core Text replaces GDI.
#   tools/win-hud-preview.sh [out.png] [scale]    scale 1.5 is 144 DPI
set -euo pipefail

cd "$(dirname "$0")/.."
out="${1:-build/win-hud-preview.png}"
mkdir -p build "$(dirname "$out")"

swiftc -O -o build/win-hud-preview \
    Sources/M0110HUD/Windows/HUDRaster.swift \
    Sources/M0110HUD/HUDKind.swift \
    tools/win-hud-preview/main.swift
build/win-hud-preview "$out" "${2:-1.5}"
