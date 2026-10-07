# Copyright (c) 2026 M0110 ZMK Driver
# SPDX-License-Identifier: MIT

zephyr_library()
zephyr_library_sources_ifdef(CONFIG_ZMK_BATTERY_VDDH_OCV battery_vddh_ocv.c battery_estimator.c)
