# Copyright (c) 2024 M0110 ZMK Driver
# SPDX-License-Identifier: MIT

zephyr_library()
zephyr_library_sources_ifdef(CONFIG_KSCAN_M0110 kscan_m0110.c)

# The driver's USB-power check uses zmk_usb_is_powered() from <zmk/usb.h>, which
# lives in the main ZMK app (APPLICATION_SOURCE_DIR is zmk/app) rather than the
# ZMK Zephyr module, so that include directory is not on this out-of-tree
# library's path by default.
zephyr_library_include_directories("${APPLICATION_SOURCE_DIR}/include")
