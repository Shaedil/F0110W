/*
 * Copyright (c) 2026 M0110 ZMK Driver
 *
 * SPDX-License-Identifier: MIT
 *
 * Battery state-of-charge estimate from the nice!nano v2's VDDH reading.
 *
 * Kept free of Zephyr headers so it can be unit-tested on the host; see
 * tests/battery_estimator_test.c.
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>

/* Matches Zephyr's ocv-capacity-table-0: 0% to 100% in 10% steps. */
#define BATTERY_ESTIMATOR_OCV_POINTS 11

struct battery_estimator_config {
    /* Resting cell voltage at 0%, 10%, ... 100%, in microvolts, ascending. */
    int32_t ocv_uv[BATTERY_ESTIMATOR_OCV_POINTS];
    /* VDDH-minus-cell offset on USB to assume until one has been measured. */
    int32_t charger_offset_uv;
    /* Fastest the cell can really gain charge, in milli-percent per hour. */
    int32_t max_rise_mpct_per_hour;
};

struct battery_estimator {
    const struct battery_estimator_config *config;
    bool primed;
    /* The previous sample, kept to measure the charger offset across a USB edge. */
    bool on_usb;
    int32_t vddh_uv;
    int64_t at_ms;
    /* Charger offset in use; measured on this board once offset_measured is set. */
    int32_t offset_uv;
    bool offset_measured;
    /* Filtered cell voltage, and the state of charge reported from it. */
    int32_t cell_uv;
    int32_t soc_mpct;
    bool rising;
};

void battery_estimator_init(struct battery_estimator *est,
                            const struct battery_estimator_config *config);

/*
 * Feed one VDDH sample.  on_usb is true when the nice!nano's USB-C has VBUS,
 * which on this build also means the bq25185 is charging the cell.
 */
void battery_estimator_update(struct battery_estimator *est, int32_t vddh_uv, bool on_usb,
                              int64_t now_ms);

/* Interpolate a resting cell voltage on the OCV table, in milli-percent. */
int32_t battery_estimator_ocv_to_mpct(const int32_t ocv_uv[BATTERY_ESTIMATOR_OCV_POINTS],
                                      int32_t cell_uv);
