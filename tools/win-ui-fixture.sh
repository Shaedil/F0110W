#!/bin/sh
# Rebuilds WindowsUI/fixture.json (sample data for browser previews) from the shared Swift.
set -e
cd "$(dirname "$0")/.."
src=Sources/M0110HUD
out=$(mktemp -d)
swiftc -O -o "$out/fixture" \
    $src/Studio/Models.swift $src/Studio/Protobuf.swift $src/Studio/HIDKeycodes.swift \
    $src/Studio/Behaviors.swift $src/Studio/StudioClient.swift $src/Studio/Transport.swift \
    $src/Studio/BLETransport.swift \
    $src/UI/CapLegend.swift $src/UI/M0110Layout.swift \
    $src/Windows/BoardCase.swift $src/Windows/KeymapModel.swift \
    tools/win-ui-fixture/main.swift
"$out/fixture" WindowsUI/fixture.json
rm -rf "$out"
