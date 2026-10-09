/*
 * Copyright (c) 2026 M0110 ZMK Driver
 * SPDX-License-Identifier: MIT
 *
 * Tell each connected computer which Bluetooth profile the keyboard types to,
 * and what each profile is called.
 *
 * ZMK stays connected to every paired computer at once and only routes key
 * reports to the active profile, so switching profile leaves every link up.
 * From a computer's side of the radio nothing happens: it stays connected and
 * stops getting keys, and without this service it cannot tell why.
 *
 * The state characteristic, readable and notifiable, holds:
 *
 *   active:u8  the profile the keyboard types to, 0-based
 *   own:u8     the profile that is the computer reading it, or 0xFF if that
 *              computer is not bonded to one
 *   names:u8   goes up by one whenever a profile's name changes
 *
 * `own` differs per computer, so a change is notified to each connection
 * separately rather than broadcast. It is sent whenever ZMK raises
 * zmk_ble_active_profile_changed: on a switch, and also when the active
 * profile's computer connects, drops or pairs, when nothing may have moved.
 * Readers keep the last value and act only on a change. Fields are only
 * ever appended, so a reader takes the bytes it knows and ignores the rest.
 *
 * The names characteristic holds the profiles' names in the format
 * profile_names.h describes, and takes writes from any bonded computer:
 *
 *   SET  op:u8=1 index:u8 name...  names a profile; an empty name clears it
 *   AUTO op:u8=2 index:u8 name...  names a profile only if it has no name,
 *                                  numbering any others that share it
 *
 * A name belongs to the computer bonded to its profile when it was given, so
 * one that pairs there later, after the profile was cleared, starts without
 * one. A name given to a profile no computer is bonded to goes to the first
 * that pairs with it. Names are kept in settings, apart from ZMK's own.
 */

#include <stdio.h>
#include <string.h>

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/settings/settings.h>

#include <zmk/ble.h>
#include <zmk/event_manager.h>
#include <zmk/events/ble_active_profile_changed.h>

#include "profile_names.h"

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

#define PROFILE_UUID(num) BT_UUID_128_ENCODE(num, 0x1160, 0x4b0f, 0xb56d, 0x700006aaefeb)
#define PROFILE_SERVICE_UUID BT_UUID_DECLARE_128(PROFILE_UUID(0x05b3a8eb))
#define PROFILE_STATE_UUID BT_UUID_DECLARE_128(PROFILE_UUID(0x05b3a8ec))
#define PROFILE_NAMES_UUID BT_UUID_DECLARE_128(PROFILE_UUID(0x05b3a8ed))

#define PROFILE_STATE_LEN 3
#define PROFILE_OWN_UNKNOWN 0xFF

#define NAMES_OP_SET 0x01
#define NAMES_OP_AUTO 0x02

/* A notification that found no buffer is tried again this often, this many
 * times. The value is state, not an event, so sending it twice is harmless
 * and the last attempt to land is the one that counts. */
#define RETRY_MS 100
#define RETRY_LIMIT 20

/* What is saved per profile. Every field is bytes, so there is no padding,
 * and all zeroes is BT_ADDR_LE_ANY with no name. */
struct name_slot {
    /* The computer the name was given to, or BT_ADDR_LE_ANY if none was
     * bonded to the profile then. */
    bt_addr_le_t peer;
    struct pname name;
};

static struct name_slot slots[ZMK_BLE_PROFILE_COUNT];
static uint8_t names_generation;
/* Profiles whose slot has changed since it was last saved. */
static uint32_t unsaved;
static K_MUTEX_DEFINE(names_lock);

static void broadcast_soon(void);
static void save(struct k_work *work);
static K_WORK_DEFINE(save_work, save);

static bool same_addr(const bt_addr_le_t *a, const bt_addr_le_t *b) {
    return bt_addr_le_cmp(a, b) == 0;
}

/* Fits the names to the profiles as they are bonded now: a name waiting for a
 * computer goes to the one that has paired, and a name whose computer has
 * gone goes with it. Caller holds `names_lock`. Returns whether a name
 * changed. */
static bool reconcile(void) {
    bool changed = false;

    for (int i = 0; i < ZMK_BLE_PROFILE_COUNT; i++) {
        struct name_slot *slot = &slots[i];
        const bt_addr_le_t *bonded = zmk_ble_profile_address(i);

        if (same_addr(&slot->peer, bonded)) {
            continue;
        }
        if (same_addr(&slot->peer, BT_ADDR_LE_ANY)) {
            if (slot->name.len > 0) {
                bt_addr_le_copy(&slot->peer, bonded);
                unsaved |= BIT(i);
            }
            continue;
        }

        LOG_DBG("profile %d has a new computer; dropping its name", i);
        memset(slot, 0, sizeof(*slot));
        unsaved |= BIT(i);
        changed = true;
    }

    return changed;
}

/* Caller holds `names_lock`. */
static void names_changed(void) {
    names_generation++;
    broadcast_soon();
}

static void encode_state(struct bt_conn *conn, uint8_t out[PROFILE_STATE_LEN]) {
    int own = zmk_ble_profile_index(bt_conn_get_dst(conn));

    out[0] = (uint8_t)zmk_ble_active_profile_index();
    out[1] = own < 0 ? PROFILE_OWN_UNKNOWN : (uint8_t)own;
    out[2] = names_generation;
}

static ssize_t state_read(struct bt_conn *conn, const struct bt_gatt_attr *attr, void *buf,
                          uint16_t len, uint16_t offset) {
    uint8_t state[PROFILE_STATE_LEN];

    encode_state(conn, state);
    return bt_gatt_attr_read(conn, attr, buf, len, offset, state, sizeof(state));
}

/* Longer than one packet, so a host reads it in pieces, each a call here. A
 * name that changes between pieces can tear the value, but the change also
 * moves the state's counter, which has every host read the names again. */
static ssize_t names_read(struct bt_conn *conn, const struct bt_gatt_attr *attr, void *buf,
                          uint16_t len, uint16_t offset) {
    struct pname names[ZMK_BLE_PROFILE_COUNT];
    uint8_t value[PNAME_ENCODED_MAX(ZMK_BLE_PROFILE_COUNT)];

    k_mutex_lock(&names_lock, K_FOREVER);
    if (reconcile()) {
        names_changed();
    }
    for (int i = 0; i < ZMK_BLE_PROFILE_COUNT; i++) {
        names[i] = slots[i].name;
    }
    k_mutex_unlock(&names_lock);

    if (unsaved) {
        k_work_submit(&save_work);
    }

    size_t value_len = pname_encode(names, ZMK_BLE_PROFILE_COUNT, value, sizeof(value));
    return bt_gatt_attr_read(conn, attr, buf, len, offset, value, value_len);
}

static ssize_t names_write(struct bt_conn *conn, const struct bt_gatt_attr *attr, const void *buf,
                           uint16_t len, uint16_t offset, uint8_t flags) {
    ARG_UNUSED(attr);
    const uint8_t *in = buf;

    if (flags & BT_GATT_WRITE_FLAG_PREPARE) {
        return 0;
    }
    if (offset != 0) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_OFFSET);
    }
    if (len < 2) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }
    /* As for the clipboard, an encrypted link is not enough: only a computer
     * the keyboard types to may name anything. */
    if (zmk_ble_profile_index(bt_conn_get_dst(conn)) < 0) {
        return BT_GATT_ERR(BT_ATT_ERR_WRITE_NOT_PERMITTED);
    }

    uint8_t op = in[0];
    uint8_t index = in[1];
    const uint8_t *text = &in[2];
    size_t text_len = len - 2;

    if (index >= ZMK_BLE_PROFILE_COUNT || !pname_valid(text, text_len)) {
        return BT_GATT_ERR(BT_ATT_ERR_VALUE_NOT_ALLOWED);
    }

    k_mutex_lock(&names_lock, K_FOREVER);
    bool changed = reconcile();
    int result = 0;

    if (op == NAMES_OP_SET) {
        struct name_slot *slot = &slots[index];

        if (slot->name.len != text_len || memcmp(slot->name.text, text, text_len) != 0) {
            memset(slot, 0, sizeof(*slot));
            memcpy(slot->name.text, text, text_len);
            slot->name.len = (uint8_t)text_len;
            bt_addr_le_copy(&slot->peer,
                            text_len > 0 ? zmk_ble_profile_address(index) : BT_ADDR_LE_ANY);
            result = BIT(index);
        }
    } else if (op == NAMES_OP_AUTO) {
        struct pname names[ZMK_BLE_PROFILE_COUNT];

        for (int i = 0; i < ZMK_BLE_PROFILE_COUNT; i++) {
            names[i] = slots[i].name;
        }
        result = pname_auto(names, ZMK_BLE_PROFILE_COUNT, index, text, text_len);
        for (int i = 0; result > 0 && i < ZMK_BLE_PROFILE_COUNT; i++) {
            if (result & BIT(i)) {
                slots[i].name = names[i];
            }
        }
        if (result & BIT(index)) {
            bt_addr_le_copy(&slots[index].peer, zmk_ble_profile_address(index));
        }
    } else {
        result = -ENOTSUP;
    }

    if (result > 0) {
        unsaved |= (uint32_t)result;
        changed = true;
    }
    if (changed) {
        names_changed();
    }
    k_mutex_unlock(&names_lock);

    if (unsaved) {
        k_work_submit(&save_work);
    }

    if (result == -ENOTSUP) {
        return BT_GATT_ERR(BT_ATT_ERR_NOT_SUPPORTED);
    }
    if (result < 0) {
        return BT_GATT_ERR(BT_ATT_ERR_VALUE_NOT_ALLOWED);
    }
    return len;
}

/* Named to sort after every other static service, the clipboard's included:
 * services are laid out in name order, and adding one at the end leaves the
 * handles paired hosts have cached where they were. The names characteristic
 * goes after the state's CCC for the same reason. */
BT_GATT_SERVICE_DEFINE(zmk_profile_svc, BT_GATT_PRIMARY_SERVICE(PROFILE_SERVICE_UUID),
                       BT_GATT_CHARACTERISTIC(PROFILE_STATE_UUID,
                                              BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY,
                                              BT_GATT_PERM_READ_ENCRYPT, state_read, NULL, NULL),
                       BT_GATT_CCC(NULL, BT_GATT_PERM_READ_ENCRYPT | BT_GATT_PERM_WRITE_ENCRYPT),
                       BT_GATT_CHARACTERISTIC(PROFILE_NAMES_UUID,
                                              BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE,
                                              BT_GATT_PERM_READ_ENCRYPT |
                                                  BT_GATT_PERM_WRITE_ENCRYPT,
                                              names_read, names_write, NULL));

#define STATE_ATTR (&zmk_profile_svc.attrs[2])
#define NAMES_ATTR (&zmk_profile_svc.attrs[5])

/* Saved from the work queue: settings can block on flash, and changes come
 * from the Bluetooth thread. */
static void save(struct k_work *work) {
    ARG_UNUSED(work);
    struct name_slot copy[ZMK_BLE_PROFILE_COUNT];

    k_mutex_lock(&names_lock, K_FOREVER);
    uint32_t pending = unsaved;
    unsaved = 0;
    memcpy(copy, slots, sizeof(copy));
    k_mutex_unlock(&names_lock);

#if IS_ENABLED(CONFIG_SETTINGS)
    for (int i = 0; i < ZMK_BLE_PROFILE_COUNT; i++) {
        if (pending & BIT(i)) {
            char key[24];

            snprintf(key, sizeof(key), "m0110/pname/%d", i);
            int err = settings_save_one(key, &copy[i], sizeof(copy[i]));
            if (err) {
                /* Tried again with the next change or read. */
                LOG_ERR("could not save profile %d's name: %d", i, err);
                k_mutex_lock(&names_lock, K_FOREVER);
                unsaved |= BIT(i);
                k_mutex_unlock(&names_lock);
            }
        }
    }
#else
    ARG_UNUSED(pending);
    ARG_UNUSED(copy);
#endif
}

#if IS_ENABLED(CONFIG_SETTINGS)

static int names_settings_set(const char *key, size_t len, settings_read_cb read_cb,
                              void *cb_arg) {
    struct name_slot slot;

    if (key[0] < '0' || key[0] >= '0' + ZMK_BLE_PROFILE_COUNT || key[1] != '\0') {
        return -ENOENT;
    }
    if (len != sizeof(slot) || read_cb(cb_arg, &slot, sizeof(slot)) != sizeof(slot) ||
        !pname_valid((const uint8_t *)slot.name.text, slot.name.len)) {
        return -EINVAL;
    }

    k_mutex_lock(&names_lock, K_FOREVER);
    slots[key[0] - '0'] = slot;
    k_mutex_unlock(&names_lock);
    return 0;
}

SETTINGS_STATIC_HANDLER_DEFINE(m0110_pname, "m0110/pname", NULL, names_settings_set, NULL, NULL);
#endif

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

static void broadcast_soon(void) {
    retries_left = RETRY_LIMIT;
    k_work_reschedule(&broadcast_work, K_NO_WAIT);
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
 * inside a key press, and a notification may have to wait for a buffer. The
 * event also comes whenever a profile is paired or cleared, which is when a
 * name can lose its computer. */
static int profile_report_listener(const zmk_event_t *eh) {
    const struct zmk_ble_active_profile_changed *ev = as_zmk_ble_active_profile_changed(eh);

    if (ev) {
        LOG_DBG("profile %d active; telling connected hosts", ev->index);
        k_mutex_lock(&names_lock, K_FOREVER);
        if (reconcile()) {
            names_generation++;
        }
        k_mutex_unlock(&names_lock);
        if (unsaved) {
            k_work_submit(&save_work);
        }
        broadcast_soon();
    }

    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(profile_report, profile_report_listener);
ZMK_SUBSCRIPTION(profile_report, zmk_ble_active_profile_changed);
