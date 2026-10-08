/*
 * Copyright (c) 2026 M0110 ZMK Driver
 * SPDX-License-Identifier: MIT
 *
 * Tell each connected computer which Bluetooth profile the keyboard types to.
 *
 * ZMK stays connected to every paired computer at once and only routes key
 * reports to the active profile, so switching profile leaves every link up.
 * From a computer's side of the radio nothing happens: it stays connected,
 * and simply stops getting keys. This service is how it finds out.
 *
 * One characteristic, readable and notifiable, holds two bytes:
 *
 *   active:u8  the profile the keyboard types to, 0-based
 *   own:u8     the profile that is the computer reading it, or 0xFF if that
 *              computer is not bonded to one
 *
 * `own` differs per computer, so a change is notified to each connection
 * separately rather than broadcast. It is sent whenever ZMK raises
 * zmk_ble_active_profile_changed: on a switch, and also when the active
 * profile's computer connects, drops or pairs, when nothing may have moved.
 * Readers keep the last value and act only on a change. Fields are only
 * ever appended, so a reader takes the first two bytes and ignores the rest.
 */

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include <zmk/ble.h>
#include <zmk/event_manager.h>
#include <zmk/events/ble_active_profile_changed.h>

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

#define PROFILE_UUID(num) BT_UUID_128_ENCODE(num, 0x1160, 0x4b0f, 0xb56d, 0x700006aaefeb)
#define PROFILE_SERVICE_UUID BT_UUID_DECLARE_128(PROFILE_UUID(0x05b3a8eb))
#define PROFILE_STATE_UUID BT_UUID_DECLARE_128(PROFILE_UUID(0x05b3a8ec))

#define PROFILE_STATE_LEN 2
#define PROFILE_OWN_UNKNOWN 0xFF

/* A notification that found no buffer is tried again this often, this many
 * times. The value is state, not an event, so sending it twice is harmless
 * and the last attempt to land is the one that counts. */
#define RETRY_MS 100
#define RETRY_LIMIT 20

static void encode_state(struct bt_conn *conn, uint8_t out[PROFILE_STATE_LEN]) {
    int own = zmk_ble_profile_index(bt_conn_get_dst(conn));

    out[0] = (uint8_t)zmk_ble_active_profile_index();
    out[1] = own < 0 ? PROFILE_OWN_UNKNOWN : (uint8_t)own;
}

static ssize_t state_read(struct bt_conn *conn, const struct bt_gatt_attr *attr, void *buf,
                          uint16_t len, uint16_t offset) {
    uint8_t state[PROFILE_STATE_LEN];

    encode_state(conn, state);
    return bt_gatt_attr_read(conn, attr, buf, len, offset, state, sizeof(state));
}

/* Named to sort after every other static service, the clipboard's included:
 * services are laid out in name order, and adding one at the end leaves the
 * handles paired hosts have cached where they were. */
BT_GATT_SERVICE_DEFINE(zmk_profile_svc, BT_GATT_PRIMARY_SERVICE(PROFILE_SERVICE_UUID),
                       BT_GATT_CHARACTERISTIC(PROFILE_STATE_UUID,
                                              BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY,
                                              BT_GATT_PERM_READ_ENCRYPT, state_read, NULL, NULL),
                       BT_GATT_CCC(NULL, BT_GATT_PERM_READ_ENCRYPT | BT_GATT_PERM_WRITE_ENCRYPT));

#define STATE_ATTR (&zmk_profile_svc.attrs[2])

static void broadcast(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(broadcast_work, broadcast);
static int retries_left;

static bool is_backpressure(int err) {
    return err == -ENOMEM || err == -ENOBUFS || err == -EAGAIN;
}

/* Errors other than running out of buffers mean this connection is not
 * listening, for now or for good: not subscribed, not encrypted, going away. */
static void notify_one(struct bt_conn *conn, void *data) {
    bool *retry = data;
    struct bt_conn_info info;
    uint8_t state[PROFILE_STATE_LEN];

    if (bt_conn_get_info(conn, &info) != 0 || info.role != BT_CONN_ROLE_PERIPHERAL) {
        return;
    }

    encode_state(conn, state);
    int err = bt_gatt_notify(conn, STATE_ATTR, state, sizeof(state));
    if (is_backpressure(err)) {
        *retry = true;
    }
}

static void broadcast(struct k_work *work) {
    ARG_UNUSED(work);
    bool retry = false;

    bt_conn_foreach(BT_CONN_TYPE_LE, notify_one, &retry);

    if (retry && retries_left-- > 0) {
        k_work_reschedule(&broadcast_work, K_MSEC(RETRY_MS));
    }
}

/* Sent from the work queue rather than here: the event can be raised from
 * inside a key press, and a notification may have to wait for a buffer. */
static int profile_report_listener(const zmk_event_t *eh) {
    const struct zmk_ble_active_profile_changed *ev = as_zmk_ble_active_profile_changed(eh);

    if (ev) {
        LOG_DBG("profile %d active; telling connected hosts", ev->index);
        retries_left = RETRY_LIMIT;
        k_work_reschedule(&broadcast_work, K_NO_WAIT);
    }

    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(profile_report, profile_report_listener);
ZMK_SUBSCRIPTION(profile_report, zmk_ble_active_profile_changed);
