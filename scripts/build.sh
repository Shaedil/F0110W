#!/bin/bash
#
# Builds the ZMK firmware.
# Run from the repository root directory.
#
# Usage:
#   ./scripts/build.sh              # Full build (west init, update, build)
#   ./scripts/build.sh --quick      # Quick build (skip west init/update)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

do_west_init() {
    log_info "Initializing West workspace..."

    if [ -d "$REPO_ROOT/.west" ]; then
        log_info "West already initialized, skipping..."
    else
        west init -l "$REPO_ROOT/config"
    fi
}

do_west_update() {
    log_info "Updating West modules..."
    west update
}

# Zephyr splits path lists on whitespace in several places and emits some paths
# into the compiler/linker command line unquoted, so a tree checked out under a
# path containing a space cannot build at all. scripts/zephyr-space-path.patch
# fixes those sites. west update restores the pristine zephyr/ tree, so
# re-apply after every update.
apply_space_path_patch() {
    local patch="$SCRIPT_DIR/zephyr-space-path.patch"

    [ -f "$patch" ] || { log_warn "Missing $patch"; return 0; }

    case "$REPO_ROOT" in
        *\ *) ;;
        *) log_info "No spaces in the repository path; skipping the Zephyr space-path patch."
           return 0 ;;
    esac

    if git -C "$REPO_ROOT/zephyr" apply --reverse --check "$patch" 2>/dev/null; then
        log_info "Zephyr space-path patch already applied."
    elif git -C "$REPO_ROOT/zephyr" apply "$patch" 2>/dev/null; then
        log_success "Applied Zephyr space-path patch."
    else
        log_error "Could not apply $patch; the build will fail from a path with spaces."
        return 1
    fi
}

do_build() {
    apply_space_path_patch

    log_info "Building ZMK firmware..."

    # gnuarmemb toolchain from Homebrew; Zephyr isn't registered in the CMake
    # package registry, so point at this workspace's copy explicitly.
    export ZEPHYR_TOOLCHAIN_VARIANT=gnuarmemb
    export GNUARMEMB_TOOLCHAIN_PATH=/opt/homebrew
    export ZEPHYR_BASE="$REPO_ROOT/zephyr"

    west build -s zmk/app -b nice_nano -- \
        -DSHIELD=m0110 \
        -DZMK_CONFIG="$REPO_ROOT/config" \
        -DZephyr_DIR="$REPO_ROOT/zephyr/share/zephyr-package/cmake"

    log_success "Build complete!"

    # Copy firmware to repo root for easy access
    if [ -f "$REPO_ROOT/build/zephyr/zmk.uf2" ]; then
        cp "$REPO_ROOT/build/zephyr/zmk.uf2" "$REPO_ROOT/zmk_working.uf2"
        log_success "Firmware copied to: $REPO_ROOT/zmk_working.uf2"
    fi
}

show_help() {
    echo "Builds the ZMK firmware"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --quick       Skip west init/update (faster rebuild)"
    echo "  --help        Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                    # Full build"
    echo "  $0 --quick            # Quick rebuild"
}

# Parse arguments
QUICK=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --quick)
            QUICK=true
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Change to repo root
cd "$REPO_ROOT"

if [ "$QUICK" = false ]; then
    do_west_init
    do_west_update
fi

do_build

log_success "All done!"
echo ""
echo "To flash the firmware:"
echo "  1. Put your nice!nano in bootloader mode (double-tap reset)"
echo "  2. Copy zmk_working.uf2 to the mounted drive"
