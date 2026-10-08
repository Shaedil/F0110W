#!/usr/bin/env bash
#
# Host-side tests for the battery estimator, the clipboard module and the
# profile report. No Zephyr workspace needed.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

: "${CC:=cc}"

"$CC" -std=c11 -Wall -Wextra -Werror -O1 \
    -o "$out/battery_estimator_test" \
    "$here/battery_estimator_test.c" \
    "$root/config/drivers/sensor/battery_estimator.c"
"$out/battery_estimator_test"

pure=("$root/config/clipboard/clip_proto.c" "$root/config/clipboard/clip_text.c")

# The wire format and the text-to-keystroke map, which have no dependencies.
"$CC" -std=c11 -Wall -Wextra -Werror -O1 \
    -o "$out/clipboard_test" \
    "$here/clipboard_test.c" "${pure[@]}"
"$out/clipboard_test"

# clipboard.c itself, against tests/fake standing in for Zephyr and ZMK.
"$CC" -std=c11 -Wall -Wextra -Werror -O1 \
    -I "$here/fake" \
    -o "$out/clipboard_sim_test" \
    "$here/clipboard_sim_test.c" "${pure[@]}"
"$out/clipboard_sim_test"

# The same with the limit on messages between helpers below the limit on text,
# where it cannot hide behind the size of the buffer.
"$CC" -std=c11 -Wall -Wextra -Werror -O1 \
    -DCLIP_TEST_SMALL_OPAQUE -DCONFIG_ZMK_CLIPBOARD_OPAQUE_MAX_LEN=64 \
    -Wno-unused-function -Wno-unused-const-variable \
    -I "$here/fake" \
    -o "$out/clipboard_sim_small" \
    "$here/clipboard_sim_test.c" "${pure[@]}"
"$out/clipboard_sim_small"

# profile_report.c, against the same fakes.
"$CC" -std=c11 -Wall -Wextra -Werror -O1 \
    -I "$here/fake" \
    -o "$out/profile_report_test" \
    "$here/profile_report_test.c"
"$out/profile_report_test"
