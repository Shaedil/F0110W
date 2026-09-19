# Copyright (c) 2024 M0110 ZMK Driver
# SPDX-License-Identifier: MIT

zephyr_library()
zephyr_library_sources_ifdef(CONFIG_KSCAN_M0110 kscan_m0110.c)
