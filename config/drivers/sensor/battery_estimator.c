/*
 * Copyright (c) 2026 M0110 ZMK Driver
 *
 * SPDX-License-Identifier: MIT
 *
 * ZMK's stock estimate
 * --------------------
 * The nice!nano v2 has no battery divider: ZMK reads VDDH, and VDDH is the
 * bq24072 charger's OUT rail, not the cell.  While the nice!nano's USB port has
 * VBUS, the bq24072 holds OUT at VBAT + 225 mV (datasheet: 150 to 270 mV), or
 * at 3.4 V when VBAT is under 3.2 V.  ZMK then maps millivolts to percent with
 * one straight line from 3450 mV to 4200 mV, so plugging in reads about 30
 * points high at once, and on battery the bottom of the range reads 15 to 25
 * points high because a LiPo's curve is not a line.
 *
 * On this build the bq25185 board's USB lines are wired through to the
 * nice!nano's USB-C, so one cable feeds both chargers.  Whenever VBUS is
 * present the cell is also taking up to 1 A from the bq25185, which lifts its
 * terminal voltage by I*R through the cell, JST and wiring.  VDDH therefore
 * sits above the resting cell voltage by the bq24072's offset plus that I*R.
 *
 * This estimator
 * --------------
 *  - Subtracts that combined offset while VBUS is present.  It varies from part
 *    to part and with wiring, so it is measured whenever two samples straddle a
 *    USB plug or unplug: the cell's charge cannot move far in that time, so the
 *    step is the chargers'.
 *  - Looks the cell voltage up on a resting-voltage (OCV) table instead of a line.
 *  - Never reports a gain faster than the chargers could really deliver.
 *  - Ignores small rises on battery.  Voltage rebounds when the M0110's boost
 *    load drops, which is not charge.
 *
 * The offset is measured with the charge current at plug-in.  As the bq25185
 * tapers its current towards the end of a charge, I*R shrinks and the estimate
 * reads low until the cable comes out.
 */

#include "battery_estimator.h"

/* Plausible offsets: the datasheet's 150-270 mV, plus I*R at up to 1.1 A of charge. */
#define OFFSET_MIN_UV 100000
#define OFFSET_MAX_UV 500000

/* Below VBAT 3.2 V the bq24072 clamps OUT at 3.4 V, so the step is not the offset. */
#define LEARN_MIN_CELL_UV 3300000

/*
 * Two samples further apart than this do not straddle a USB edge closely enough
 * to measure the offset.  The driver samples at least once a minute, even while
 * ZMK is idle and has stopped asking.
 */
#define EDGE_MAX_AGE_MS (3 * 60 * 1000)

/* A rise smaller than this on battery is load rebound, not charge. */
#define RISE_HYSTERESIS_MPCT 3000

/* Exponential filter weight: each sample moves the estimate by 1/EMA_DIVISOR. */
#define EMA_DIVISOR 4

#define MS_PER_HOUR (60LL * 60 * 1000)

void battery_estimator_init(struct battery_estimator *est,
                            const struct battery_estimator_config *config) {
    *est = (struct battery_estimator){
        .config = config,
        .offset_uv = config->charger_offset_uv,
    };
}

int32_t battery_estimator_ocv_to_mpct(const int32_t ocv_uv[BATTERY_ESTIMATOR_OCV_POINTS],
                                      int32_t cell_uv) {
    if (cell_uv <= ocv_uv[0]) {
        return 0;
    }

    for (int i = 1; i < BATTERY_ESTIMATOR_OCV_POINTS; i++) {
        if (cell_uv < ocv_uv[i]) {
            int64_t into = cell_uv - ocv_uv[i - 1];
            int64_t span = ocv_uv[i] - ocv_uv[i - 1];

            return (i - 1) * 10000 + (int32_t)(into * 10000 / span);
        }
    }

    return 100000;
}

static void measure_offset(struct battery_estimator *est, int32_t vddh_uv, bool on_usb,
                           int64_t now_ms) {
    if (now_ms - est->at_ms > EDGE_MAX_AGE_MS) {
        return;
    }

    int32_t usb_uv = on_usb ? vddh_uv : est->vddh_uv;
    int32_t battery_uv = on_usb ? est->vddh_uv : vddh_uv;
    int32_t offset_uv = usb_uv - battery_uv;

    if (battery_uv < LEARN_MIN_CELL_UV || offset_uv < OFFSET_MIN_UV ||
        offset_uv > OFFSET_MAX_UV) {
        return;
    }

    est->offset_uv = offset_uv;
    est->offset_measured = true;
}

static int32_t next_soc(struct battery_estimator *est, int32_t target_mpct, int64_t elapsed_ms) {
    int32_t soc_mpct = est->soc_mpct;

    if (target_mpct < soc_mpct) {
        est->rising = false;
        return target_mpct;
    }

    /* Once a rise is under way, keep following it so a full charge reaches 100%. */
    if (!est->rising && target_mpct - soc_mpct <= RISE_HYSTERESIS_MPCT) {
        return soc_mpct;
    }

    est->rising = true;

    int64_t step_mpct = est->config->max_rise_mpct_per_hour * elapsed_ms / MS_PER_HOUR;

    if (target_mpct - soc_mpct <= step_mpct) {
        return target_mpct;
    }

    return soc_mpct + (int32_t)step_mpct;
}

void battery_estimator_update(struct battery_estimator *est, int32_t vddh_uv, bool on_usb,
                              int64_t now_ms) {
    if (est->primed && on_usb != est->on_usb) {
        measure_offset(est, vddh_uv, on_usb, now_ms);
    }

    int32_t cell_uv = on_usb ? vddh_uv - est->offset_uv : vddh_uv;

    if (!est->primed) {
        est->cell_uv = cell_uv;
        est->soc_mpct = battery_estimator_ocv_to_mpct(est->config->ocv_uv, cell_uv);
    } else {
        /* Round away from zero so the filter settles exactly on a steady input. */
        int32_t diff_uv = cell_uv - est->cell_uv;
        int32_t round_uv = diff_uv > 0 ? EMA_DIVISOR - 1 : -(EMA_DIVISOR - 1);

        est->cell_uv += (diff_uv + round_uv) / EMA_DIVISOR;
        est->soc_mpct =
            next_soc(est, battery_estimator_ocv_to_mpct(est->config->ocv_uv, est->cell_uv),
                     now_ms - est->at_ms);
    }

    est->primed = true;
    est->on_usb = on_usb;
    est->vddh_uv = vddh_uv;
    est->at_ms = now_ms;
}
