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
static int flash_writes;
/* Saves that fail before one goes through. */
static int flash_failures;

int settings_save_one(const char *name, const void *value, size_t val_len) {
    int index = -1;

    if (flash_failures > 0) {
        flash_failures--;
        return -EIO;
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

/* Runs broadcast_work until it stops rescheduling itself or `until` passes. */
static void run_until(int64_t until) {
    while (broadcast_work.scheduled && broadcast_work.due <= until) {
        now = broadcast_work.due;
        broadcast_work.scheduled = false;
        broadcast_work.work.handler(&broadcast_work.work);
    }
    now = until;
}

/* ---- Connections ---- */

#define BONDED_NONE 0xFF

struct bt_conn {
    bt_addr_le_t addr;
    uint8_t role;
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
    conn->subscribed = true;
    return conn;
}

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
    flash_writes = 0;
    flash_failures = 0;
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
        func(&conns[i], data);
    }
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
    CHECK(p == at);
    return name;
}

static void test_names_start_empty(void) {
    reset();
    bonded[0] = 10;
    struct bt_conn *mac = add_conn(10, BT_CONN_ROLE_PERIPHERAL);
    uint8_t buf[32];

    CHECK(NAMES_ATTR->read(mac, NAMES_ATTR, buf, sizeof(buf), 0) == 2 + ZMK_BLE_PROFILE_COUNT);
    CHECK(buf[0] == PNAME_FORMAT && buf[1] == ZMK_BLE_PROFILE_COUNT);
    for (int i = 0; i < ZMK_BLE_PROFILE_COUNT; i++) {
        CHECK(buf[2 + i] == 0);
    }
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
    test_numbering();

    if (failures) {
        printf("profile_report: %d failure(s)\n", failures);
        return 1;
    }
    printf("profile_report: all scenarios passed\n");
    return 0;
}
