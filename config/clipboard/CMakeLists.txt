# Copyright (c) 2026 M0110 ZMK Driver
# SPDX-License-Identifier: MIT

# Added to ZMK's own `app` target rather than built as a library of this
# module. The code includes ZMK's internal headers, which are only on that
# target's include path. ZMK also runs event listeners in link order: a
# module's CMake is processed before ZMK lists its sources, so these land
# ahead of ZMK's HID listener, which is what lets a paste be swallowed before
# it reaches the host. clipboard.c checks that at boot.
target_sources(app PRIVATE
  clipboard.c
  clip_proto.c
  clip_text.c
)
