# Copyright (c) 2026 M0110 ZMK Driver
# SPDX-License-Identifier: MIT

zephyr_library()
zephyr_library_sources_ifdef(CONFIG_ZMK_BATTERY_REPORT_WHILE_IDLE battery_idle_report.c)

# <zmk/activity.h> and the event headers live in the main ZMK app
# (APPLICATION_SOURCE_DIR is zmk/app), not on an out-of-tree library's path.
zephyr_library_include_directories("${APPLICATION_SOURCE_DIR}/include")
