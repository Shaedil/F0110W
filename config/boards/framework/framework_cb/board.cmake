# Copyright (c) 2026 The ZMK Contributors
# SPDX-License-Identifier: MIT

# The board carries SWD pads (SWD/SWC/SWO/SWV on the back) for recovery.  The
# normal route for a signed application image is MCUboot serial recovery over
# USB CDC ACM, which is driven by mcumgr rather than by a Zephyr runner.
board_runner_args(jlink "--device=nRF54LM20A_M33" "--speed=4000")

include(${ZEPHYR_BASE}/boards/common/jlink.board.cmake)
