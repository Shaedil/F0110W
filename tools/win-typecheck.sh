#!/usr/bin/env bash
# Type-checks the Windows build's Swift on a Mac. The shared files are copied with
# their Darwin and CoreBluetooth branches turned off, since Windows has neither.
set -euo pipefail

cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

{
    printf 'module CM0110Win {\n  header "%s/Sources/CM0110Win/include/CM0110Win.h"\n  export *\n}\n' "$PWD"
    printf 'module CM0110Web {\n  header "%s/Sources/CM0110Web/include/CM0110Web.h"\n  export *\n}\n' "$PWD"
} > "$work/module.modulemap"

shared=$(sed -n '/^let shared = \[/,/^\]/p' Package.swift | grep -o '"[^"]*\.swift"' | tr -d '"')
mkdir -p "$work/src"
sources=()
for file in $shared; do
    copy="$work/src/${file//\//_}"
    sed -e 's/#if canImport(Darwin)/#if false/' -e 's/#if canImport(CoreBluetooth)/#if false/' \
        "Sources/M0110HUD/$file" > "$copy"
    sources+=("$copy")
done

swiftc -typecheck -module-name M0110HUD -I "$work" "${sources[@]}" Sources/M0110HUD/Windows/*.swift
echo "Windows Swift layer type-checks."
