/*
 * Copyright (c) 2026 M0110 ZMK Driver
 * SPDX-License-Identifier: MIT
 *
 * Keep the BLE Battery Service current while the keyboard is idle.
 *
 * ZMK's battery.c stops its sampling timer when activity goes idle (30 s after
 * the last key) and starts it again on the next key.  Hosts keep reading the
 * Battery Level characteristic in between, so a keyboard left alone for days
 * reports whatever it read the last time anyone typed.  This takes over while
 * ZMK is idle, on the same interval and work queue, and hands back on the next
 * key.
 *
 * Only the BAS value is refreshed.  zmk_battery_state_of_charge() and the
 * battery_state_changed event stay with ZMK and catch up on the next key;
 * nothing on this board reads them while idle.
 */

#include <zephyr/device.h>
#include <zephyr/kernel.h>
#include <zephyr/drivers/sensor.h>
#include <zephyr/bluetooth/services/bas.h>
#include <zephyr/logging/log.h>

#include <zmk/activity.h>
#include <zmk/event_manager.h>
#include <zmk/events/activity_state_changed.h>
#include <zmk/workqueue.h>

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

BUILD_ASSERT(DT_HAS_CHOSEN(zmk_battery), "No zmk,battery chosen node");

static const struct device *const battery = DEVICE_DT_GET(DT_CHOSEN(zmk_battery));

static void idle_report_work(struct k_work *work) {
    struct sensor_value soc;

    if (!device_is_ready(battery)) {
        return;
    }

    int rc = sensor_sample_fetch_chan(battery, SENSOR_CHAN_GAUGE_STATE_OF_CHARGE);
    if (rc == 0) {
        rc = sensor_channel_get(battery, SENSOR_CHAN_GAUGE_STATE_OF_CHARGE, &soc);
    }
    if (rc != 0) {
        LOG_DBG("Idle battery read failed: %d", rc);
        return;
    }

    uint8_t level = CLAMP(soc.val1, 0, 100);

    if (bt_bas_get_battery_level() != level) {
        LOG_DBG("Idle: setting BAS battery level to %d", level);
        rc = bt_bas_set_battery_level(level);
        if (rc != 0) {
            LOG_WRN("Idle: failed to set BAS battery level: %d", rc);
        }
    }
}

K_WORK_DEFINE(idle_report_work_item, idle_report_work);

static void idle_report_timer_fn(struct k_timer *timer) {
    k_work_submit_to_queue(zmk_workqueue_lowprio_work_q(), &idle_report_work_item);
}

K_TIMER_DEFINE(idle_report_timer, idle_report_timer_fn, NULL);

static int idle_report_listener(const zmk_event_t *eh) {
    if (zmk_activity_get_state() == ZMK_ACTIVITY_IDLE) {
        /* ZMK sampled moments ago, so the first idle report waits a full interval. */
        k_timer_start(&idle_report_timer, K_SECONDS(CONFIG_ZMK_BATTERY_REPORT_INTERVAL),
                      K_SECONDS(CONFIG_ZMK_BATTERY_REPORT_INTERVAL));
    } else {
        k_timer_stop(&idle_report_timer);
    }

    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(battery_idle_report, idle_report_listener);
ZMK_SUBSCRIPTION(battery_idle_report, zmk_activity_state_changed);
