#!/usr/bin/env bash
#
# Host-side tests for the M0110 wire decoder.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

: "${CC:=cc}"

"$CC" -std=c11 -Wall -Wextra -Werror -O1 \
    -o "$out/m0110_decode_test" \
    "$here/m0110_decode_test.c" \
    "$root/config/drivers/input/m0110_decode.c"

"$out/m0110_decode_test"
