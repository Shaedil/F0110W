# Copyright (c) 2024 M0110 ZMK Driver
# SPDX-License-Identifier: MIT

add_subdirectory(drivers)
add_subdirectory(src)

if(CONFIG_ZMK_CLIPBOARD)
  add_subdirectory(clipboard)
endif()
