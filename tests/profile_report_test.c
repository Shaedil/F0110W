/*
 * Copyright (c) 2026 M0110 ZMK Driver
 * SPDX-License-Identifier: MIT
 *
 * Drives the real config/src/profile_report.c on a host, against tests/fake.
 *
 * Each scenario sets up some connections, raises the profile event and runs
 * the work queue, then checks what each connection was told. The file is
 * included rather than linked so the scenarios can reset its static state.
 * The naming rules in profile_names.c are linked as they are.
 */

#include <stdio.h>
#include <string.h>

#include "fake/fake.h"

#include "../config/src/profile_report.c"

static int failures;

#define CHECK(cond)                                                                                \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                                 \
            failures++;                                                                            \
        }                                                                                          \
    } while (0)

const struct zmk_event_type zmk_event_zmk_ble_active_profile_changed = {"ble_active_profile_changed"};
const struct zmk_event_type zmk_event_zmk_keycode_state_changed = {"keycode_state_changed"};
const struct zmk_event_type zmk_event_zmk_endpoint_changed = {"endpoint_changed"};
const struct zmk_event_type zmk_event_zmk_position_state_changed = {"position_state_changed"};

/* ---- Work queue on a virtual clock ---- */

static int64_t now;

int64_t k_uptime_get(void) { return now; }

int k_work_reschedule(struct k_work_delayable *work, k_timeout_t delay) {
    work->due = now + delay.ms;
    work->scheduled = true;
    return 1;
}

int k_work_cancel_delayable(struct k_work_delayable *work) {
    work->scheduled = false;
    return 0;
}

int k_work_submit(struct k_work *work) {
    work->pending = true;
    return 1;
}

static int lock_depth;

int k_mutex_lock(struct k_mutex *mutex, k_timeout_t timeout) {
    (void)mutex;
    (void)timeout;
    lock_depth++;
    return 0;
}

int k_mutex_unlock(struct k_mutex *mutex) {
    (void)mutex;
    CHECK(lock_depth > 0);
    lock_depth--;
    return 0;
}

/* ---- Settings ---- */

static struct name_slot flash[ZMK_BLE_PROFILE_COUNT];
static uint8_t flash_from_device;
static int flash_writes;
/* Saves that fail before one goes through. */
static int flash_failures;

int settings_save_one(const char *name, const void *value, size_t val_len) {
    int index = -1;

    if (flash_failures > 0) {
        flash_failures--;
        return -EIO;
    }

    if (strcmp(name, "m0110/pname/dev") == 0) {
        CHECK(val_len == 1);
        flash_from_device = *(const uint8_t *)value;
        flash_writes++;
        return 0;
    }
    CHECK(sscanf(name, "m0110/pname/%d", &index) == 1);
    CHECK(index >= 0 && index < ZMK_BLE_PROFILE_COUNT);
    CHECK(val_len == sizeof(struct name_slot));
    memcpy(&flash[index], value, sizeof(struct name_slot));
    flash_writes++;
    return 0;
}

static void run_saves(void) {
    if (save_work.pending) {
        save_work.pending = false;
        save_work.handler(&save_work);
    }
}

static ssize_t read_from(void *cb_arg, void *data, size_t len) {
    memcpy(data, cb_arg, len);
    return (ssize_t)len;
}

/* The delayed work due soonest, by `until`. */
static struct k_work_delayable *next_due(int64_t until) {
    struct k_work_delayable *works[] = {&broadcast_work, &device_name_work};
    struct k_work_delayable *soonest = NULL;

    for (size_t i = 0; i < ARRAY_SIZE(works); i++) {
        if (works[i]->scheduled && works[i]->due <= until &&
            (!soonest || works[i]->due < soonest->due)) {
            soonest = works[i];
        }
    }
    return soonest;
}

/* Runs the delayed work, in the order it falls due, until none is left by
 * `until`. */
static void run_until(int64_t until) {
    struct k_work_delayable *work;

    while ((work = next_due(until))) {
        now = work->due;
        work->scheduled = false;
        work->work.handler(&work->work);
    }
    now = until;
}

/* ---- Connections ---- */

#define BONDED_NONE 0xFF

struct bt_conn {
    bt_addr_le_t addr;
    uint8_t role;
    bt_security_t security;
    /* Holds taken with bt_conn_ref and not yet given back. */
    int refs;
    bool gone;
    bool subscribed;
    /* Notifications this link refuses for want of a buffer before it takes one. */
    int busy;
    uint8_t last[PROFILE_STATE_LEN];
    int notified;
};

static struct bt_conn conns[4];
static int conn_count;
/* Which address is bonded to each profile, by bt_addr_le_t.id. */
static uint8_t bonded[ZMK_BLE_PROFILE_COUNT];
static int active;

static struct bt_conn *add_conn(uint8_t id, uint8_t role) {
    struct bt_conn *conn = &conns[conn_count++];

    memset(conn, 0, sizeof(*conn));
    conn->addr.id = id;
    conn->role = role;
    conn->security = BT_SECURITY_L2;
    conn->subscribed = true;
    return conn;
}

/* The read out to a device for its name, if any. */
static struct bt_conn *read_conn;
static struct bt_gatt_read_params *read_params;
static int reads;
/* What the next bt_gatt_read returns instead of sending. */
static int read_err;

static void reset(void) {
    memset(conns, 0, sizeof(conns));
    conn_count = 0;
    memset(bonded, BONDED_NONE, sizeof(bonded));
    active = 0;
    now = 0;
    broadcast_work.scheduled = false;
    memset(slots, 0, sizeof(slots));
    names_generation = 0;
    unsaved = 0;
    save_work.pending = false;
    memset(flash, 0, sizeof(flash));
    flash_from_device = 0;
    flash_writes = 0;
    flash_failures = 0;
    from_device = 0;
    asked = 0;
    asking = NULL;
    device_name_work.scheduled = false;
    read_conn = NULL;
    read_params = NULL;
    reads = 0;
    read_err = 0;
}

bt_addr_le_t *zmk_ble_profile_address(uint8_t index) {
    static bt_addr_le_t addrs[ZMK_BLE_PROFILE_COUNT];

    addrs[index].id = bonded[index] == BONDED_NONE ? 0 : bonded[index];
    return &addrs[index];
}

int zmk_ble_active_profile_index(void) { return active; }

int zmk_ble_profile_index(const bt_addr_le_t *addr) {
    for (int i = 0; i < ZMK_BLE_PROFILE_COUNT; i++) {
        if (bonded[i] == addr->id) {
            return i;
        }
    }
    return -ENODEV;
}

const bt_addr_le_t *bt_conn_get_dst(const struct bt_conn *conn) { return &conn->addr; }

int bt_conn_get_info(const struct bt_conn *conn, struct bt_conn_info *info) {
    memset(info, 0, sizeof(*info));
    info->role = conn->role;
    return 0;
}

void bt_conn_foreach(int type, void (*func)(struct bt_conn *conn, void *data), void *data) {
    (void)type;
    for (int i = 0; i < conn_count; i++) {
        if (!conns[i].gone) {
            func(&conns[i], data);
        }
    }
}

struct bt_conn *bt_conn_ref(struct bt_conn *conn) {
    conn->refs++;
    return conn;
}

void bt_conn_unref(struct bt_conn *conn) {
    CHECK(conn->refs > 0);
    conn->refs--;
}

bt_security_t bt_conn_get_security(const struct bt_conn *conn) { return conn->security; }

int bt_gatt_read(struct bt_conn *conn, struct bt_gatt_read_params *params) {
    CHECK(params->handle_count == 0 && params->by_uuid.uuid == BT_UUID_GAP_DEVICE_NAME);
    CHECK(params->by_uuid.start_handle == 0x0001 && params->by_uuid.end_handle == 0xffff);
    CHECK(conn->refs > 0);
    if (read_err) {
        int err = read_err;
        read_err = 0;
        return err;
    }
    CHECK(read_conn == NULL);
    read_conn = conn;
    read_params = params;
    reads++;
    return 0;
}

int bt_gatt_notify(struct bt_conn *conn, const struct bt_gatt_attr *attr, const void *data,
                   uint16_t len) {
    CHECK(attr == STATE_ATTR);
    CHECK(len == PROFILE_STATE_LEN);
    if (!conn->subscribed) {
        return -EINVAL;
    }
    if (conn->busy > 0) {
        conn->busy--;
        return -ENOMEM;
    }
    memcpy(conn->last, data, len);
    conn->notified++;
    return 0;
}

ssize_t bt_gatt_attr_read(struct bt_conn *conn, const struct bt_gatt_attr *attr, void *buf,
                          uint16_t buf_len, uint16_t offset, const void *value,
                          uint16_t value_len) {
    (void)conn;
    (void)attr;
    if (offset > value_len) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_OFFSET);
    }
    uint16_t n = MIN(buf_len, value_len - offset);
    memcpy(buf, (const uint8_t *)value + offset, n);
    return n;
}

static void raise_switch(int index) {
    active = index;
    struct zmk_ble_active_profile_changed_event ev = {
        .header = {.event = &zmk_event_zmk_ble_active_profile_changed},
        .data = {.index = (uint8_t)index},
    };
    CHECK(profile_report_listener(&ev.header) == ZMK_EV_EVENT_BUBBLE);
}

/* ---- Scenarios ---- */

/* The layout the notify index assumes: service, declaration, value, CCC,
 * then the names' declaration and value. */
static void test_layout(void) {
    CHECK(zmk_profile_svc.attr_count == 6);
    CHECK(STATE_ATTR->read == state_read);
    CHECK(NAMES_ATTR->read == names_read && NAMES_ATTR->write == names_write);
}

/* Each computer reads the active profile and its own. */
static void test_read(void) {
    reset();
    bonded[0] = 10; /* the Mac */
    bonded[1] = 11; /* Windows */
    active = 1;
    struct bt_conn *mac = add_conn(10, BT_CONN_ROLE_PERIPHERAL);
    struct bt_conn *stranger = add_conn(99, BT_CONN_ROLE_PERIPHERAL);
    uint8_t buf[8];

    CHECK(STATE_ATTR->read(mac, STATE_ATTR, buf, sizeof(buf), 0) == 3);
    CHECK(buf[0] == 1 && buf[1] == 0 && buf[2] == 0);

    CHECK(STATE_ATTR->read(stranger, STATE_ATTR, buf, sizeof(buf), 0) == 3);
    CHECK(buf[0] == 1 && buf[1] == PROFILE_OWN_UNKNOWN);
}

/* A switch reaches every subscribed computer, each with its own profile, and
 * nothing goes out until the work queue runs. */
static void test_switch(void) {
    reset();
    bonded[0] = 10;
    bonded[1] = 11;
    struct bt_conn *mac = add_conn(10, BT_CONN_ROLE_PERIPHERAL);
    struct bt_conn *win = add_conn(11, BT_CONN_ROLE_PERIPHERAL);
    struct bt_conn *quiet = add_conn(12, BT_CONN_ROLE_PERIPHERAL);
    quiet->subscribed = false;

    raise_switch(1);
    CHECK(mac->notified == 0 && win->notified == 0);

    run_until(0);
    CHECK(mac->notified == 1 && mac->last[0] == 1 && mac->last[1] == 0);
    CHECK(win->notified == 1 && win->last[0] == 1 && win->last[1] == 1);
    CHECK(quiet->notified == 0);
    CHECK(!broadcast_work.scheduled);
}

/* A link out of buffers gets the value once it has one; the others are told
 * again, which is harmless. */
static void test_backpressure(void) {
    reset();
    bonded[0] = 10;
    bonded[1] = 11;
    struct bt_conn *mac = add_conn(10, BT_CONN_ROLE_PERIPHERAL);
    struct bt_conn *win = add_conn(11, BT_CONN_ROLE_PERIPHERAL);
    mac->busy = 2;

    raise_switch(1);
    run_until(0);
    CHECK(mac->notified == 0);
    CHECK(broadcast_work.scheduled && broadcast_work.due == RETRY_MS);

    run_until(1000);
    CHECK(mac->notified == 1 && mac->last[0] == 1 && mac->last[1] == 0);
    CHECK(win->notified >= 1 && win->last[0] == 1);
    CHECK(!broadcast_work.scheduled);
}

/* A link that never frees up is given up on rather than retried forever. */
static void test_retry_limit(void) {
    reset();
    bonded[0] = 10;
    struct bt_conn *mac = add_conn(10, BT_CONN_ROLE_PERIPHERAL);
    mac->busy = 1000;

    raise_switch(2);
    run_until(60 * 1000);
    CHECK(mac->notified == 0);
    CHECK(!broadcast_work.scheduled);
    CHECK(mac->busy == 1000 - (RETRY_LIMIT + 1));
}

/* A second switch while a retry is pending sends the newer state. */
static void test_switch_during_retry(void) {
    reset();
    bonded[0] = 10;
    struct bt_conn *mac = add_conn(10, BT_CONN_ROLE_PERIPHERAL);
    mac->busy = 1;

    raise_switch(1);
    run_until(0);
    CHECK(mac->notified == 0);

    raise_switch(0);
    run_until(1000);
    CHECK(mac->notified == 1 && mac->last[0] == 0 && mac->last[1] == 0);
}

/* Connections the keyboard opened itself, as a split central does, are not
 * computers it types to. */
static void test_skips_central_role(void) {
    reset();
    bonded[0] = 10;
    struct bt_conn *half = add_conn(20, BT_CONN_ROLE_CENTRAL);

    raise_switch(0);
    run_until(0);
    CHECK(half->notified == 0);
}


/* ---- Names ---- */

static ssize_t write_name(struct bt_conn *conn, uint8_t op, uint8_t index, const char *name) {
    uint8_t frame[64];
    size_t len = strlen(name);

    frame[0] = op;
    frame[1] = index;
    memcpy(&frame[2], name, len);
    return NAMES_ATTR->write(conn, NAMES_ATTR, frame, (uint16_t)(2 + len), 0, 0);
}

/* The from_device byte from the last read_name. */
static uint8_t read_from_device;

/* Reads the names characteristic in pieces of `chunk`, as a host does when it
 * is longer than a packet, and returns profile `index`'s name. */
static const char *read_name(struct bt_conn *conn, int index, uint16_t chunk) {
    static char name[PNAME_MAX + 1];
    uint8_t value[PNAME_ENCODED_MAX(ZMK_BLE_PROFILE_COUNT)];
    uint16_t at = 0;
    ssize_t n;

    while ((n = NAMES_ATTR->read(conn, NAMES_ATTR, &value[at], chunk, at)) > 0) {
        at += (uint16_t)n;
    }
    CHECK(n == 0);
    CHECK(lock_depth == 0);
    CHECK(at >= 2 && value[0] == PNAME_FORMAT && value[1] == ZMK_BLE_PROFILE_COUNT);

    uint16_t p = 2;
    for (int i = 0; i < ZMK_BLE_PROFILE_COUNT; i++) {
        CHECK(p < at);
        uint8_t len = value[p++];
        if (i == index) {
            memcpy(name, &value[p], len);
            name[len] = '\0';
        }
        p += len;
    }
    CHECK(p + 1 == at);
    read_from_device = value[p];
    return name;
}

static void test_names_start_empty(void) {
    reset();
    bonded[0] = 10;
    struct bt_conn *mac = add_conn(10, BT_CONN_ROLE_PERIPHERAL);
    uint8_t buf[32];

    CHECK(NAMES_ATTR->read(mac, NAMES_ATTR, buf, sizeof(buf), 0) == 3 + ZMK_BLE_PROFILE_COUNT);
    CHECK(buf[0] == PNAME_FORMAT && buf[1] == ZMK_BLE_PROFILE_COUNT);
    for (int i = 0; i < ZMK_BLE_PROFILE_COUNT; i++) {
        CHECK(buf[2 + i] == 0);
    }
    CHECK(buf[2 + ZMK_BLE_PROFILE_COUNT] == 0);
}

/* A name given on one computer is what every computer reads, each is told it
 * changed, and it is saved. */
static void test_set_reaches_everyone(void) {
    reset();
    bonded[0] = 10;
    bonded[1] = 11;
    struct bt_conn *mac = add_conn(10, BT_CONN_ROLE_PERIPHERAL);
    struct bt_conn *win = add_conn(11, BT_CONN_ROLE_PERIPHERAL);

    CHECK(write_name(mac, NAMES_OP_SET, 1, "Gaming PC") == 11);
    CHECK(strcmp(read_name(win, 1, 20), "Gaming PC") == 0);
    CHECK(strcmp(read_name(mac, 0, 20), "") == 0);

    run_until(0);
    CHECK(mac->notified == 1 && mac->last[2] == 1);
    CHECK(win->notified == 1 && win->last[2] == 1);

    run_saves();
    CHECK(flash_writes == 1);
    CHECK(flash[1].peer.id == 11 && flash[1].name.len == 9);

    /* The same name again changes nothing. */
    CHECK(write_name(mac, NAMES_OP_SET, 1, "Gaming PC") == 11);
    run_until(1000);
    CHECK(mac->notified == 1);

    /* An empty name clears it. */
    CHECK(write_name(win, NAMES_OP_SET, 1, "") == 2);
    CHECK(strcmp(read_name(mac, 1, 64), "") == 0);
    run_saves();
    CHECK(flash[1].name.len == 0 && flash[1].peer.id == 0);
}

/* A computer names itself only where there is no name yet. */
static void test_auto_only_fills_blanks(void) {
    reset();
    bonded[0] = 10;
    struct bt_conn *mac = add_conn(10, BT_CONN_ROLE_PERIPHERAL);

    CHECK(write_name(mac, NAMES_OP_SET, 0, "Work") == 6);
    run_until(0);
    int told = mac->notified;

    CHECK(write_name(mac, NAMES_OP_AUTO, 0, "MacBook Air M4") == 16);
    CHECK(strcmp(read_name(mac, 0, 64), "Work") == 0);
    run_until(1000);
    CHECK(mac->notified == told);
}

/* Two of the same computer are told apart by number, and the first is
 * renumbered when the second arrives. */
static void test_auto_numbers_twins(void) {
    reset();
    bonded[0] = 10;
    bonded[1] = 11;
    bonded[2] = 12;
    struct bt_conn *a = add_conn(10, BT_CONN_ROLE_PERIPHERAL);
    struct bt_conn *b = add_conn(11, BT_CONN_ROLE_PERIPHERAL);
    struct bt_conn *c = add_conn(12, BT_CONN_ROLE_PERIPHERAL);

    CHECK(write_name(a, NAMES_OP_AUTO, 0, "MacBook Pro M4") == 16);
    CHECK(strcmp(read_name(a, 0, 64), "MacBook Pro M4") == 0);

    CHECK(write_name(b, NAMES_OP_AUTO, 1, "MacBook Pro M4") == 16);
    CHECK(strcmp(read_name(a, 0, 64), "MacBook Pro M4 1") == 0);
    CHECK(strcmp(read_name(a, 1, 64), "MacBook Pro M4 2") == 0);

    CHECK(write_name(c, NAMES_OP_AUTO, 2, "MacBook Pro M4") == 16);
    CHECK(strcmp(read_name(a, 2, 64), "MacBook Pro M4 3") == 0);

    run_saves();
    CHECK(flash[0].name.len == 16 && flash[0].peer.id == 10);
    CHECK(flash[1].peer.id == 11 && flash[2].peer.id == 12);
}

/* A profile cleared and paired to another computer loses its old name. */
static void test_new_computer_drops_name(void) {
    reset();
    bonded[0] = 10;
    bonded[1] = 11;
    struct bt_conn *mac = add_conn(10, BT_CONN_ROLE_PERIPHERAL);

    CHECK(write_name(mac, NAMES_OP_SET, 1, "Windows 11 PC") == 15);
    run_until(0);
    run_saves();
    int told = mac->notified;

    bonded[1] = BONDED_NONE;
    raise_switch(1);
    run_until(1000);
    CHECK(mac->notified == told + 1 && mac->last[2] == 2);
    CHECK(strcmp(read_name(mac, 1, 64), "") == 0);
    run_saves();
    CHECK(flash[1].name.len == 0);

    bonded[1] = 13;
    raise_switch(1);
    CHECK(strcmp(read_name(mac, 1, 64), "") == 0);
}

/* A name given to an empty profile goes to whatever pairs there, and leaves
 * with it. */
static void test_name_before_pairing(void) {
    reset();
    bonded[0] = 10;
    struct bt_conn *mac = add_conn(10, BT_CONN_ROLE_PERIPHERAL);

    CHECK(write_name(mac, NAMES_OP_SET, 3, "Apple TV") == 10);
    run_saves();
    CHECK(flash[3].peer.id == 0);

    bonded[3] = 30;
    raise_switch(3);
    CHECK(strcmp(read_name(mac, 3, 64), "Apple TV") == 0);
    run_saves();
    CHECK(flash[3].peer.id == 30);

    bonded[3] = BONDED_NONE;
    raise_switch(3);
    CHECK(strcmp(read_name(mac, 3, 64), "") == 0);
}

static void test_bad_writes(void) {
    reset();
    bonded[0] = 10;
    struct bt_conn *mac = add_conn(10, BT_CONN_ROLE_PERIPHERAL);
    struct bt_conn *stranger = add_conn(99, BT_CONN_ROLE_PERIPHERAL);
    uint8_t one = NAMES_OP_SET;

    CHECK(write_name(stranger, NAMES_OP_SET, 0, "Mine") ==
          BT_GATT_ERR(BT_ATT_ERR_WRITE_NOT_PERMITTED));
    CHECK(NAMES_ATTR->write(mac, NAMES_ATTR, &one, 1, 0, 0) ==
          BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN));
    CHECK(write_name(mac, NAMES_OP_SET, ZMK_BLE_PROFILE_COUNT, "x") ==
          BT_GATT_ERR(BT_ATT_ERR_VALUE_NOT_ALLOWED));
    CHECK(write_name(mac, NAMES_OP_SET, 0, "tab\there") ==
          BT_GATT_ERR(BT_ATT_ERR_VALUE_NOT_ALLOWED));
    CHECK(write_name(mac, NAMES_OP_SET, 0, "1234567890123456789012345") ==
          BT_GATT_ERR(BT_ATT_ERR_VALUE_NOT_ALLOWED));
    CHECK(write_name(mac, NAMES_OP_AUTO, 0, "1234567890123456789012") ==
          BT_GATT_ERR(BT_ATT_ERR_VALUE_NOT_ALLOWED));
    CHECK(write_name(mac, NAMES_OP_AUTO, 0, "") == BT_GATT_ERR(BT_ATT_ERR_VALUE_NOT_ALLOWED));
    CHECK(write_name(mac, 0x7E, 0, "x") == BT_GATT_ERR(BT_ATT_ERR_NOT_SUPPORTED));
    CHECK(NAMES_ATTR->write(mac, NAMES_ATTR, "\x01\x00x", 3, 1, 0) ==
          BT_GATT_ERR(BT_ATT_ERR_INVALID_OFFSET));
    CHECK(lock_depth == 0);

    /* The longest name fits, multi-byte characters and all. */
    CHECK(write_name(mac, NAMES_OP_SET, 0, "123456789012345678901234") == 26);
    CHECK(write_name(mac, NAMES_OP_SET, 1, "Caf\xc3\xa9") == 7);
    CHECK(strcmp(read_name(mac, 1, 7), "Caf\xc3\xa9") == 0);
}

/* A save that fails is tried again rather than lost. */
static void test_failed_save_retried(void) {
    reset();
    bonded[0] = 10;
    struct bt_conn *mac = add_conn(10, BT_CONN_ROLE_PERIPHERAL);

    flash_failures = 1;
    CHECK(write_name(mac, NAMES_OP_SET, 0, "Desk") == 6);
    run_saves();
    CHECK(flash_writes == 0 && unsaved == BIT(0));

    read_name(mac, 0, 64);
    run_saves();
    CHECK(flash_writes == 1 && flash[0].name.len == 4 && unsaved == 0);
}

/* Names come back from settings at boot. */
static void test_settings_load(void) {
    reset();
    bonded[2] = 12;
    struct bt_conn *pc = add_conn(12, BT_CONN_ROLE_PERIPHERAL);
    struct name_slot saved = {.peer = {.id = 12}, .name = {.len = 4, .text = "Desk"}};
    struct name_slot bad = {.peer = {.id = 12}, .name = {.len = 4, .text = "D\x01sk"}};

    CHECK(fake_settings_m0110_pname.set("2", sizeof(saved), read_from, &saved) == 0);
    CHECK(fake_settings_m0110_pname.set("5", sizeof(saved), read_from, &saved) == -ENOENT);
    CHECK(fake_settings_m0110_pname.set("1", sizeof(saved) - 1, read_from, &saved) == -EINVAL);
    CHECK(fake_settings_m0110_pname.set("1", sizeof(bad), read_from, &bad) == -EINVAL);
    CHECK(strcmp(fake_settings_m0110_pname.subtree, "m0110/pname") == 0);

    CHECK(strcmp(read_name(pc, 2, 64), "Desk") == 0);
    CHECK(strcmp(read_name(pc, 1, 64), "") == 0);
}

/* ---- Names read from the devices themselves ---- */

/* A link comes up encrypted, as it does each time a bonded device connects. */
static void secure(struct bt_conn *conn) {
    conn->security = BT_SECURITY_L2;
    profile_names_conn_cb.security_changed(conn, BT_SECURITY_L2, BT_SECURITY_ERR_SUCCESS);
}

static void drop(struct bt_conn *conn) {
    conn->gone = true;
    profile_names_conn_cb.disconnected(conn, 0x13);
}

/* The device answers the read out to it with `name`, or has none to give. */
static void answer(const char *name, size_t len) {
    struct bt_conn *conn = read_conn;
    struct bt_gatt_read_params *params = read_params;

    CHECK(conn != NULL);
    if (!conn) {
        return;
    }
    read_conn = NULL;
    if (name) {
        CHECK(params->func(conn, 0, params, name, (uint16_t)len) == BT_GATT_ITER_STOP);
    } else {
        params->func(conn, 0x0A, params, NULL, 0);
    }
}

#define ANSWER(name) answer(name, strlen(name))

/* A phone, which has no helper, is named after itself once it has been
 * connected a while, and the name says where it came from. */
static void test_phone_named_after_itself(void) {
    reset();
    bonded[0] = 10;
    bonded[3] = 40;
    struct bt_conn *mac = add_conn(10, BT_CONN_ROLE_PERIPHERAL);
    struct bt_conn *phone = add_conn(40, BT_CONN_ROLE_PERIPHERAL);

    /* The Mac's helper named it on connect. */
    CHECK(write_name(mac, NAMES_OP_AUTO, 0, "MacBook Air M4") == 16);
    run_until(0);
    int told = mac->notified;

    secure(phone);
    run_until(DEVICE_NAME_DELAY_MS - 1);
    CHECK(reads == 0);
    run_until(DEVICE_NAME_DELAY_MS);
    CHECK(reads == 1 && read_conn == phone);

    ANSWER("Galaxy S9");
    CHECK(strcmp(read_name(mac, 3, 64), "Galaxy S9") == 0);
    CHECK(read_from_device == BIT(3));
    CHECK(phone->refs == 0);

    run_until(DEVICE_NAME_DELAY_MS + 1000);
    CHECK(mac->notified == told + 1 && mac->last[2] == 2);
    CHECK(reads == 1);

    run_saves();
    CHECK(flash[3].peer.id == 40 && flash[3].name.len == 9);
    CHECK(flash_from_device == BIT(3));
}

/* A computer whose helper names it on connect is never asked. */
static void test_helper_names_first(void) {
    reset();
    bonded[0] = 10;
    struct bt_conn *mac = add_conn(10, BT_CONN_ROLE_PERIPHERAL);

    secure(mac);
    run_until(500);
    CHECK(write_name(mac, NAMES_OP_AUTO, 0, "MacBook Air M4") == 16);
    run_until(DEVICE_NAME_DELAY_MS + 5000);
    CHECK(reads == 0);
    CHECK(strcmp(read_name(mac, 0, 64), "MacBook Air M4") == 0);
    CHECK(read_from_device == 0);
}

/* A computer named after itself before its helper ran is renamed by the
 * helper, and the name is no longer marked as the device's. */
static void test_helper_replaces_device_name(void) {
    reset();
    bonded[1] = 11;
    struct bt_conn *pc = add_conn(11, BT_CONN_ROLE_PERIPHERAL);

    secure(pc);
    run_until(DEVICE_NAME_DELAY_MS);
    ANSWER("DESKTOP-7F3K2");
    CHECK(strcmp(read_name(pc, 1, 64), "DESKTOP-7F3K2") == 0);
    CHECK(read_from_device == BIT(1));
    run_saves();

    CHECK(write_name(pc, NAMES_OP_AUTO, 1, "Windows 11 PC") == 15);
    CHECK(strcmp(read_name(pc, 1, 64), "Windows 11 PC") == 0);
    CHECK(read_from_device == 0);
    run_saves();
    CHECK(flash_from_device == 0 && flash[1].name.len == 13);

    /* And it stays the helper's: a second AUTO changes nothing. */
    CHECK(write_name(pc, NAMES_OP_AUTO, 1, "Something Else") == 16);
    CHECK(strcmp(read_name(pc, 1, 64), "Windows 11 PC") == 0);
}

/* A name given by hand beats the device's, even one that reads the same. */
static void test_hand_name_beats_device(void) {
    reset();
    bonded[0] = 10;
    bonded[3] = 40;
    struct bt_conn *mac = add_conn(10, BT_CONN_ROLE_PERIPHERAL);
    struct bt_conn *phone = add_conn(40, BT_CONN_ROLE_PERIPHERAL);

    CHECK(write_name(mac, NAMES_OP_SET, 0, "Desk") == 6);
    secure(phone);
    run_until(DEVICE_NAME_DELAY_MS);
    CHECK(read_conn == phone);
    ANSWER("Galaxy S9");
    CHECK(strcmp(read_name(mac, 3, 64), "Galaxy S9") == 0);
    CHECK(read_from_device == BIT(3));

    CHECK(write_name(mac, NAMES_OP_SET, 3, "Galaxy S9") == 11);
    CHECK(strcmp(read_name(mac, 3, 64), "Galaxy S9") == 0);
    CHECK(read_from_device == 0);
    CHECK(write_name(phone, NAMES_OP_AUTO, 3, "Phone") == 7);
    CHECK(strcmp(read_name(mac, 3, 64), "Galaxy S9") == 0);
}

/* Two of the same phone are numbered as two of the same computer are. */
static void test_device_twins(void) {
    reset();
    bonded[2] = 30;
    bonded[3] = 40;
    struct bt_conn *a = add_conn(30, BT_CONN_ROLE_PERIPHERAL);
    struct bt_conn *b = add_conn(40, BT_CONN_ROLE_PERIPHERAL);

    secure(a);
    secure(b);
    run_until(DEVICE_NAME_DELAY_MS);
    CHECK(reads == 1);
    ANSWER("Galaxy S9");
    run_until(DEVICE_NAME_DELAY_MS);
    CHECK(reads == 2);
    ANSWER("Galaxy S9");
    CHECK(strcmp(read_name(a, 2, 64), "Galaxy S9 1") == 0);
    CHECK(strcmp(read_name(a, 3, 64), "Galaxy S9 2") == 0);
    CHECK(read_from_device == (BIT(2) | BIT(3)));
    CHECK(a->refs == 0 && b->refs == 0);
}

/* Only an encrypted link to a bonded device, typing to a profile with no
 * name, and only from the keyboard's side of it. */
static void test_who_is_asked(void) {
    reset();
    bonded[0] = 10;
    bonded[1] = 11;
    struct bt_conn *named = add_conn(10, BT_CONN_ROLE_PERIPHERAL);
    struct bt_conn *plain = add_conn(11, BT_CONN_ROLE_PERIPHERAL);
    struct bt_conn *stranger = add_conn(99, BT_CONN_ROLE_PERIPHERAL);
    struct bt_conn *central = add_conn(12, BT_CONN_ROLE_CENTRAL);

    bonded[2] = 12;
    CHECK(write_name(named, NAMES_OP_SET, 0, "Desk") == 6);
    plain->security = BT_SECURITY_L1;
    secure(named);
    secure(stranger);
    secure(central);
    profile_names_conn_cb.security_changed(plain, BT_SECURITY_L1, BT_SECURITY_ERR_SUCCESS);
    profile_names_conn_cb.security_changed(plain, BT_SECURITY_L2, BT_SECURITY_ERR_AUTH_FAIL);
    run_until(DEVICE_NAME_DELAY_MS * 3);
    CHECK(reads == 0);
}

/* A device with no name to give, or a read that fails, is not asked again
 * until it reconnects. */
static void test_no_name_asked_once_per_connection(void) {
    reset();
    bonded[3] = 40;
    struct bt_conn *phone = add_conn(40, BT_CONN_ROLE_PERIPHERAL);

    secure(phone);
    run_until(DEVICE_NAME_DELAY_MS);
    answer(NULL, 0);
    secure(phone);
    run_until(DEVICE_NAME_DELAY_MS * 3);
    CHECK(reads == 1);

    /* Nothing printable is no name either. */
    drop(phone);
    phone->gone = false;
    secure(phone);
    run_until(now + DEVICE_NAME_DELAY_MS);
    CHECK(reads == 2);
    answer("\0\0  ", 4);
    CHECK(strcmp(read_name(phone, 3, 64), "") == 0);
    CHECK(phone->refs == 0);
}

/* A link that goes while its read is out lets go of it, and the next device
 * is asked. */
static void test_drop_during_read(void) {
    reset();
    bonded[2] = 30;
    bonded[3] = 40;
    struct bt_conn *a = add_conn(30, BT_CONN_ROLE_PERIPHERAL);
    struct bt_conn *b = add_conn(40, BT_CONN_ROLE_PERIPHERAL);

    secure(a);
    secure(b);
    run_until(DEVICE_NAME_DELAY_MS);
    CHECK(read_conn == a);
    struct bt_gatt_read_params *late = read_params;
    read_conn = NULL;
    drop(a);
    CHECK(a->refs == 0);
    run_until(now);
    CHECK(read_conn == b);

    /* The dropped link's read failing afterwards changes nothing. */
    late->func(a, 0x0E, late, NULL, 0);
    CHECK(a->refs == 0 && b->refs == 1 && read_conn == b);
    ANSWER("Pixel 8");
    CHECK(strcmp(read_name(b, 3, 64), "Pixel 8") == 0);
    CHECK(strcmp(read_name(b, 2, 64), "") == 0);
}

/* No buffer for the read: tried again shortly. No answer at all: given up
 * on, and the next device asked. */
static void test_busy_and_silent(void) {
    reset();
    bonded[2] = 30;
    bonded[3] = 40;
    struct bt_conn *a = add_conn(30, BT_CONN_ROLE_PERIPHERAL);
    struct bt_conn *b = add_conn(40, BT_CONN_ROLE_PERIPHERAL);

    read_err = -ENOMEM;
    secure(a);
    run_until(DEVICE_NAME_DELAY_MS);
    CHECK(reads == 0 && a->refs == 0);
    run_until(DEVICE_NAME_DELAY_MS + DEVICE_NAME_BUSY_RETRY_MS);
    CHECK(reads == 1 && read_conn == a);

    /* a never answers. */
    read_conn = NULL;
    secure(b);
    run_until(now + DEVICE_NAME_STALE_MS);
    CHECK(a->refs == 0);
    run_until(now + DEVICE_NAME_DELAY_MS);
    CHECK(reads == 2 && read_conn == b);
    ANSWER("Pixel 8");
    CHECK(b->refs == 0);
}

/* Which names came from devices is kept across a restart. */
static void test_from_device_saved(void) {
    reset();
    bonded[3] = 40;
    struct bt_conn *phone = add_conn(40, BT_CONN_ROLE_PERIPHERAL);
    uint8_t flags = BIT(3) | BIT(7);
    struct name_slot saved = {.peer = {.id = 40}, .name = {.len = 4, .text = "S9 1"}};

    CHECK(fake_settings_m0110_pname.set("dev", 1, read_from, &flags) == 0);
    CHECK(fake_settings_m0110_pname.set("dev", 2, read_from, &flags) == -EINVAL);
    CHECK(fake_settings_m0110_pname.set("3", sizeof(saved), read_from, &saved) == 0);
    CHECK(strcmp(read_name(phone, 3, 64), "S9 1") == 0);
    CHECK(read_from_device == BIT(3));

    /* A new device on the profile takes the mark away with the name. */
    bonded[3] = 41;
    raise_switch(3);
    CHECK(strcmp(read_name(phone, 3, 64), "") == 0);
    CHECK(read_from_device == 0);
    run_saves();
    CHECK(flash_from_device == 0);
}

/* ---- The naming rules on their own ---- */

static struct pname named(const char *text) {
    struct pname n = {.len = (uint8_t)strlen(text)};
    memcpy(n.text, text, n.len);
    return n;
}

static bool is(const struct pname *n, const char *text) {
    return n->len == strlen(text) && memcmp(n->text, text, n->len) == 0;
}

static int auto_name(struct pname *names, int index, const char *base) {
    return pname_auto(names, 5, index, (const uint8_t *)base, strlen(base));
}

static void test_numbering(void) {
    struct pname names[5];

    /* A free number below the taken ones is given out first. */
    memset(names, 0, sizeof(names));
    names[0] = named("PC 2");
    CHECK(auto_name(names, 1, "PC") == BIT(1));
    CHECK(is(&names[1], "PC 1") && is(&names[0], "PC 2"));

    /* Names that only start the same are left alone. */
    memset(names, 0, sizeof(names));
    names[0] = named("MacBook Pro M4 Max");
    names[1] = named("MacBook Pro M42");
    names[2] = named("MacBook Pro M4 01");
    CHECK(auto_name(names, 3, "MacBook Pro M4") == BIT(3));
    CHECK(is(&names[3], "MacBook Pro M4"));

    /* Two bare ones, as two computers that named themselves by hand. */
    memset(names, 0, sizeof(names));
    names[0] = named("PC");
    names[2] = named("PC");
    CHECK(auto_name(names, 4, "PC") == (BIT(0) | BIT(2) | BIT(4)));
    CHECK(is(&names[0], "PC 1") && is(&names[2], "PC 2") && is(&names[4], "PC 3"));

    /* The longest base still has room for its number. */
    memset(names, 0, sizeof(names));
    names[0] = named("123456789012345678901");
    CHECK(auto_name(names, 1, "123456789012345678901") == (BIT(0) | BIT(1)));
    CHECK(is(&names[1], "123456789012345678901 2"));

    CHECK(auto_name(names, 1, "x") == 0);
    CHECK(auto_name(names, 5, "x") == -EINVAL);
}

static bool cleans_to(const char *in, size_t len, const char *want) {
    uint8_t out[PNAME_AUTO_MAX];
    size_t n = pname_clean((const uint8_t *)in, len, out);
    return n == strlen(want) && memcmp(out, want, n) == 0;
}

#define CLEANS_TO(in, want) cleans_to(in, sizeof(in) - 1, want)

static void test_clean(void) {
    CHECK(CLEANS_TO("Galaxy S9", "Galaxy S9"));
    /* A trailing NUL, as some devices send, and other control characters. */
    CHECK(CLEANS_TO("Galaxy S9\0", "Galaxy S9"));
    CHECK(CLEANS_TO("  Sam\tsung\n ", "Samsung"));
    CHECK(CLEANS_TO("", ""));
    CHECK(CLEANS_TO(" \x01 ", ""));
    /* Cut at the limit, then any space it leaves trimmed. */
    CHECK(CLEANS_TO("123456789012345678901234567890", "123456789012345678901"));
    CHECK(CLEANS_TO("12345678901234567890 abc", "12345678901234567890"));
    /* Never through a character: "é" is two bytes and would straddle 21. */
    CHECK(CLEANS_TO("12345678901234567890\xc3\xa9", "12345678901234567890"));
    CHECK(CLEANS_TO("1234567890123456789\xc3\xa9x", "1234567890123456789\xc3\xa9"));
    /* A device that cut its own name mid-character loses the half. */
    CHECK(CLEANS_TO("Caf\xc3", "Caf"));
    CHECK(CLEANS_TO("\xf0\x9f\x93", ""));
    CHECK(CLEANS_TO("\xf0\x9f\x93\xb1 Phone", "\xf0\x9f\x93\xb1 Phone"));
}

int main(void) {
    test_layout();
    test_read();
    test_switch();
    test_backpressure();
    test_retry_limit();
    test_switch_during_retry();
    test_skips_central_role();
    test_names_start_empty();
    test_set_reaches_everyone();
    test_auto_only_fills_blanks();
    test_auto_numbers_twins();
    test_new_computer_drops_name();
    test_name_before_pairing();
    test_bad_writes();
    test_settings_load();
    test_failed_save_retried();
    test_phone_named_after_itself();
    test_helper_names_first();
    test_helper_replaces_device_name();
    test_hand_name_beats_device();
    test_device_twins();
    test_who_is_asked();
    test_no_name_asked_once_per_connection();
    test_drop_during_read();
    test_busy_and_silent();
    test_from_device_saved();
    test_numbering();
    test_clean();

    if (failures) {
        printf("profile_report: %d failure(s)\n", failures);
        return 1;
    }
    printf("profile_report: all scenarios passed\n");
    return 0;
}
