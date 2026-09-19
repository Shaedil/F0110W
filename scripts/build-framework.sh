#!/bin/bash
#
# Build the converter for the Framework control board (nRF54LM20A).
#
# This branch cannot share `master`'s west workspace: it needs Zephyr 4.4, and
# `master` needs Zephyr 4.1.  The workspace therefore lives outside the
# repository and is created by `--setup`, leaving `master`'s tree untouched.
#
# Usage:
#   ./scripts/build-framework.sh --setup     # create the workspace (~4 GB, slow)
#   ./scripts/build-framework.sh             # build the M0110 shield
#   ./scripts/build-framework.sh --smoke     # build the settings_reset shield
#   ./scripts/build-framework.sh --pristine  # discard the build directory first
#
# Override the workspace location with FRAMEWORK_WS.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

WS="${FRAMEWORK_WS:-$(dirname "$REPO_ROOT")/zmk-framework-ws}"
ZMK_FORK="https://github.com/petejohanson/zmk"
ZMK_REV="core/move-to-zephyr-4-4-0"
BOARD="${BOARD:-framework_cb/nrf54lm20a/cpuapp}"
SHIELD="m0110"
BUILD_DIR_NAME="build-framework"
MCUBOOT_KEY="$WS/mcuboot-root-ed25519.pem"
PROTOBUF_PAIR="grpcio-tools"
MCUBOOT_KEY_URL="https://raw.githubusercontent.com/mcu-tools/mcuboot/main/root-ed25519.pem"
PRISTINE=false

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

do_setup() {
    log_info "Creating the Zephyr 4.4 workspace at $WS"
    mkdir -p "$WS"
    cd "$WS"

    # ZMK keeps its manifest at app/west.yml rather than the repository root.
    west init -m "$ZMK_FORK" --mr "$ZMK_REV" --mf app/west.yml
    west update --narrow -o=--depth=1

    log_info "Creating the build virtualenv"
    /opt/homebrew/opt/python@3.12/bin/python3.12 -m venv --system-site-packages "$WS/.venv"
    "$WS/.venv/bin/python" -m pip install -q -r "$WS/zephyr/scripts/requirements-base.txt"
    "$WS/.venv/bin/python" -m pip install -q imgtool "$PROTOBUF_PAIR"

    # Framework's MCUboot branches set no CONFIG_BOOT_SIGNATURE_KEY_FILE, which
    # means the bootloader on the board trusts MCUboot's stock development key.
    log_info "Fetching the MCUboot development signing key"
    curl -fsSL "$MCUBOOT_KEY_URL" -o "$MCUBOOT_KEY"

    log_success "Workspace ready.  Run this script again to build."
}

# Zephyr splits path lists on whitespace in several places and emits some paths
# into the compiler and linker command lines unquoted, so an unpatched tree
# cannot build from a path containing a space.  west update restores the
# pristine tree, so this re-applies after every update.
apply_space_path_patch() {
    local patch="$SCRIPT_DIR/zephyr-space-path-4.4.patch"

    [ -f "$patch" ] || { log_warn "Missing $patch"; return 0; }

    case "$WS$REPO_ROOT" in
        *\ *) ;;
        *) log_info "No spaces in either path; skipping the Zephyr space-path patch."
           return 0 ;;
    esac

    if git -C "$WS/zephyr" apply --reverse --check "$patch" 2>/dev/null; then
        log_info "Zephyr space-path patch already applied."
    elif git -C "$WS/zephyr" apply "$patch" 2>/dev/null; then
        log_success "Applied Zephyr space-path patch."
    else
        log_error "Could not apply $patch; the build will fail from a path with spaces."
        return 1
    fi
}

ensure_venv() {
    if "$WS/.venv/bin/imgtool" version >/dev/null 2>&1; then
        return 0
    fi

    log_warn "The build virtualenv does not work from this path; rebuilding it."
    rm -rf "$WS/.venv"
    /opt/homebrew/opt/python@3.12/bin/python3.12 -m venv --system-site-packages "$WS/.venv"
    "$WS/.venv/bin/python" -m pip install -q -r "$WS/zephyr/scripts/requirements-base.txt"
    "$WS/.venv/bin/python" -m pip install -q imgtool
}

do_build() {
    [ -d "$WS/zephyr" ] || { log_error "No workspace at $WS.  Run with --setup first."; exit 1; }

    ensure_venv
    apply_space_path_patch

    export ZEPHYR_TOOLCHAIN_VARIANT=gnuarmemb
    export GNUARMEMB_TOOLCHAIN_PATH=/opt/homebrew
    export ZEPHYR_BASE="$WS/zephyr"
    export PATH="$WS/.venv/bin:$PATH"

    local build_dir="$WS/$BUILD_DIR_NAME"
    [ "$PRISTINE" = true ] && rm -rf "$build_dir"

    local -a extra_args=(
        -DSHIELD="$SHIELD"
        -DZephyr_DIR="$WS/zephyr/share/zephyr-package/cmake"
    )
    if [ "$SHIELD" = "m0110" ]; then
        extra_args+=(
            -DZMK_CONFIG="$REPO_ROOT/config"
            -DZMK_EXTRA_MODULES="$REPO_ROOT/config"
        )
    fi

    if [ -f "$MCUBOOT_KEY" ]; then
        extra_args+=(
            "-DCONFIG_MCUBOOT_SIGNATURE_KEY_FILE=\"$MCUBOOT_KEY\""
            -DIMGTOOL="$WS/.venv/bin/imgtool"
        )
    else
        log_warn "No signing key at $MCUBOOT_KEY; the image will be unsigned and will not boot."
    fi

    log_info "Building $SHIELD for $BOARD"
    "$WS/.venv/bin/python" -m west build -s "$WS/zmk/app" -b "$BOARD" -d "$build_dir" -- "${extra_args[@]}"

    if [ -f "$build_dir/zephyr/zmk.signed.bin" ]; then
        log_success "Signed image: $build_dir/zephyr/zmk.signed.bin"
        echo ""
        echo "To flash it:"
        echo "  1. Hold the pairing button and reset the board to enter MCUboot"
        echo "     serial recovery.  It appears as a USB CDC ACM port."
        echo "  2. mcumgr --conntype serial --connstring dev=<port>,baud=115200 \\"
        echo "       image upload $build_dir/zephyr/zmk.signed.bin"
        echo "  3. mcumgr ... reset"
    else
        log_warn "No signed image was produced; only $build_dir/zephyr/zmk.elf exists."
    fi
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --setup)    do_setup; exit 0 ;;
        --smoke)    SHIELD="settings_reset"; BUILD_DIR_NAME="build-smoke"; shift ;;
        --pristine) PRISTINE=true; shift ;;
        --help|-h)  sed -n '2,20p' "$0"; exit 0 ;;
        *)          log_error "Unknown option: $1"; exit 1 ;;
    esac
done

do_build
