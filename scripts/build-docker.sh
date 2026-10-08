#!/bin/bash
#
# Builds the ZMK firmware inside ZMK's build container, for a machine with
# Docker and no Zephyr toolchain. The workspace (zmk/, zephyr/, modules/, about
# 3 GB) is fetched into the repository root, where .gitignore already hides it.
# Run from anywhere.
#
# Usage:
#   ./scripts/build-docker.sh              # fetch the workspace if needed, then build
#   ./scripts/build-docker.sh --update     # re-run west update first
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
# Tracks the Zephyr version ZMK main builds against; see zmk/app/west.yml.
IMAGE="zmkfirmware/zmk-build-arm:4.1"

UPDATE=false
[ "$1" = "--update" ] && UPDATE=true
[ -d "$REPO_ROOT/zephyr" ] || UPDATE=true

# The board must be ZMK's variant of the nice!nano. Plain nice_nano is the
# stock board, which builds and boots but has no flash storage, battery sensor
# or external power control: it forgets every pairing at reset.
BOARD="nice_nano//zmk"

# The container's CMake package registry does not outlive the container, so
# Zephyr is pointed at explicitly, as scripts/build.sh does.
docker run --rm -v "$REPO_ROOT":/work -w /work "$IMAGE" bash -ec "
    [ -d .west ] || west init -l config
    if $UPDATE; then west update; fi
    west build -p auto -s zmk/app -b $BOARD -d build -- \
        -DSHIELD=m0110 \
        -DZMK_CONFIG=/work/config \
        -DZephyr_DIR=/work/zephyr/share/zephyr-package/cmake
"

# Stop if the build cannot store pairings, so it does not get flashed.
for symbol in CONFIG_SETTINGS_NVS CONFIG_FLASH CONFIG_ZMK_BATTERY; do
    if ! grep -q "^$symbol=y" "$REPO_ROOT/build/zephyr/.config"; then
        echo "error: $symbol is not set; this build is not for $BOARD. Do not flash it." >&2
        exit 1
    fi
done

echo ""
echo "Built: $REPO_ROOT/build/zephyr/zmk.uf2"
echo ""
echo "To flash the firmware:"
echo "  1. Put your nice!nano in bootloader mode (double-tap reset)"
echo "  2. Copy build/zephyr/zmk.uf2 to the mounted NICENANO drive"
