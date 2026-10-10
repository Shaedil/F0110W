#!/usr/bin/env bash
# Draws the Windows HUD in every state, light and dark, plus the tray icon, to
# a PNG, on a Mac. The HUD itself is software-rendered (HUDRaster.swift), so
# this is the same drawing Windows shows, with Core Text standing in for GDI.
#
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
