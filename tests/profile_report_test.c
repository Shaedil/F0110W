/*
 * Copyright (c) 2026 M0110 ZMK Driver
 * SPDX-License-Identifier: MIT
 *
 * Drives the real config/src/profile_report.c on a host, against tests/fake.
 *
 * Each scenario sets up some connections, raises the profile event and runs
 * the work queue, then checks what each connection was told. The file is
 * included rather than linked so the scenarios can reset its static state.
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

/* The layout the notify index assumes: service, declaration, value, CCC. */
static void test_layout(void) {
    CHECK(zmk_profile_svc.attr_count == 4);
    CHECK(STATE_ATTR->read == state_read);
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

    CHECK(STATE_ATTR->read(mac, STATE_ATTR, buf, sizeof(buf), 0) == 2);
    CHECK(buf[0] == 1 && buf[1] == 0);

    CHECK(STATE_ATTR->read(stranger, STATE_ATTR, buf, sizeof(buf), 0) == 2);
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

int main(void) {
    test_layout();
    test_read();
    test_switch();
    test_backpressure();
    test_retry_limit();
    test_switch_during_retry();
    test_skips_central_role();

    if (failures) {
        printf("profile_report: %d failure(s)\n", failures);
        return 1;
    }
    printf("profile_report: all scenarios passed\n");
    return 0;
}
