/*
 * Copyright (c) 2026 M0110 ZMK Driver
 * SPDX-License-Identifier: MIT
 *
 * A stand-in for the parts of Zephyr and ZMK that config/clipboard/clipboard.c
 * and config/src/profile_report.c use, so the real files can be compiled and
 * driven on a host.
 *
 * Every Zephyr and ZMK header those files include resolves to a stub next to
 * this file that includes it. Declarations only; clipboard_sim_test.c and
 * profile_report_test.c hold the behaviour: a work queue on a virtual clock, a
 * model of ZMK's HID state, and fake Bluetooth connections.
 */

#pragma once

#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

/* ---- Kconfig ---- */

/* Small, so a clip that is too long is cheap to produce. */
#define CONFIG_ZMK_CLIPBOARD_MAX_LEN 256
#ifndef CONFIG_ZMK_CLIPBOARD_OPAQUE_MAX_LEN
#define CONFIG_ZMK_CLIPBOARD_OPAQUE_MAX_LEN 1024
#endif
#define CONFIG_ZMK_CLIPBOARD_TTL_SEC 120
#define CONFIG_ZMK_CLIPBOARD_TYPE_DELAY_MS 12
#define CONFIG_ZMK_CLIPBOARD_ACK_WAIT_MS 700
#define CONFIG_ZMK_LOG_LEVEL 0
#define CONFIG_APPLICATION_INIT_PRIORITY 90
#define CONFIG_SETTINGS 1

/* Zephyr's also takes undefined options; these tests define every one used. */
#define IS_ENABLED(option) (option)

/* ---- zephyr/sys/util.h, logging, init ---- */

#define BIT(n) (1UL << (n))
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#define CLAMP(val, low, high) (((val) <= (low)) ? (low) : MIN(val, high))
#define ARRAY_SIZE(array) (sizeof(array) / sizeof((array)[0]))
#define ARG_UNUSED(x) (void)(x)
#define BUILD_ASSERT(cond, msg) _Static_assert(cond, msg)

#define LOG_MODULE_REGISTER(...) _Static_assert(1, "")
#define LOG_MODULE_DECLARE(...) _Static_assert(1, "")
/* Swallows the message but still counts its arguments as used, as the real
 * macros do. */
static inline void fake_log(const char *format, ...) { (void)format; }
#define LOG_DBG(...) fake_log(__VA_ARGS__)
#define LOG_WRN(...) fake_log(__VA_ARGS__)
#define LOG_ERR(...) fake_log(__VA_ARGS__)

#define SYS_INIT(fn, level, prio) int (*const fake_init_##fn)(void) __attribute__((unused)) = fn

/* ---- zephyr/kernel.h ---- */

typedef struct {
    int64_t ms;
} k_timeout_t;

#define K_MSEC(x) ((k_timeout_t){(x)})
#define K_SECONDS(x) K_MSEC((int64_t)(x) * 1000)
#define K_NO_WAIT K_MSEC(0)
#define K_FOREVER K_MSEC(-1)

int64_t k_uptime_get(void);

struct k_mutex {
    int depth;
};

#define K_MUTEX_DEFINE(name) struct k_mutex name

int k_mutex_lock(struct k_mutex *mutex, k_timeout_t timeout);
int k_mutex_unlock(struct k_mutex *mutex);

struct k_work {
    void (*handler)(struct k_work *work);
    bool pending;
};

struct k_work_delayable {
    struct k_work work;
    int64_t due;
    bool scheduled;
};

#define K_WORK_DEFINE(name, fn) struct k_work name = {.handler = fn}
#define K_WORK_DELAYABLE_DEFINE(name, fn) struct k_work_delayable name = {.work = {.handler = fn}}

int k_work_submit(struct k_work *work);
int k_work_reschedule(struct k_work_delayable *work, k_timeout_t delay);
int k_work_cancel_delayable(struct k_work_delayable *work);

/* ---- zephyr/bluetooth ---- */

typedef struct {
    uint8_t id;
} bt_addr_le_t;

/* Zephyr's is all zeroes, as here. */
static inline const bt_addr_le_t *fake_addr_le_any(void) {
    static const bt_addr_le_t any = {0};
    return &any;
}
#define BT_ADDR_LE_ANY fake_addr_le_any()

static inline int bt_addr_le_cmp(const bt_addr_le_t *a, const bt_addr_le_t *b) {
    return (int)a->id - (int)b->id;
}

static inline void bt_addr_le_copy(bt_addr_le_t *dst, const bt_addr_le_t *src) { *dst = *src; }

struct bt_conn;

struct bt_gatt_attr {
    ssize_t (*read)(struct bt_conn *conn, const struct bt_gatt_attr *attr, void *buf,
                    uint16_t len, uint16_t offset);
    ssize_t (*write)(struct bt_conn *conn, const struct bt_gatt_attr *attr, const void *buf,
                     uint16_t len, uint16_t offset, uint8_t flags);
    void (*ccc_changed)(const struct bt_gatt_attr *attr, uint16_t value);
};

struct bt_gatt_service_static {
    const struct bt_gatt_attr *attrs;
    size_t attr_count;
};

struct bt_conn_cb {
    void (*disconnected)(struct bt_conn *conn, uint8_t reason);
};

#define BT_ID_DEFAULT 0
#define BT_UUID_128_ENCODE(...) 0
#define BT_UUID_DECLARE_128(...) NULL

#define BT_GATT_CHRC_READ 0x02
#define BT_GATT_CHRC_WRITE 0x08
#define BT_GATT_CHRC_WRITE_WITHOUT_RESP 0x04
#define BT_GATT_CHRC_NOTIFY 0x10
#define BT_GATT_PERM_NONE 0
#define BT_GATT_PERM_READ_ENCRYPT 0x04
#define BT_GATT_PERM_WRITE_ENCRYPT 0x08
#define BT_GATT_CCC_NOTIFY 0x0001
#define BT_GATT_WRITE_FLAG_PREPARE 0x01

#define BT_ATT_ERR_WRITE_NOT_PERMITTED 0x03
#define BT_ATT_ERR_INVALID_OFFSET 0x07
#define BT_ATT_ERR_NOT_SUPPORTED 0x06
#define BT_ATT_ERR_INVALID_ATTRIBUTE_LEN 0x0d
#define BT_ATT_ERR_VALUE_NOT_ALLOWED 0x13
#define BT_GATT_ERR(code) (-(code))

/* As in Zephyr, a characteristic is two attributes: its declaration, then its
 * value. The index clipboard.c notifies on depends on that. */
#define BT_GATT_PRIMARY_SERVICE(uuid)                                                              \
    { 0 }
#define BT_GATT_CHARACTERISTIC(uuid, props, perm, _read, _write, value)                            \
    {0}, { .read = _read, .write = _write }
#define BT_GATT_CCC(changed, perm)                                                                 \
    { .ccc_changed = changed }
#define BT_GATT_SERVICE_DEFINE(name, ...)                                                          \
    static struct bt_gatt_attr attr_##name[] = {__VA_ARGS__};                                      \
    static const struct bt_gatt_service_static name = {.attrs = attr_##name,                       \
                                                       .attr_count = ARRAY_SIZE(attr_##name)}

#define BT_CONN_CB_DEFINE(name) static struct bt_conn_cb name __attribute__((unused))

#define BT_CONN_TYPE_LE 0x01
#define BT_CONN_ROLE_CENTRAL 0
#define BT_CONN_ROLE_PERIPHERAL 1

struct bt_conn_info {
    uint8_t role;
    struct {
        uint16_t interval; /* units of 1.25 ms */
    } le;
};

int bt_conn_get_info(const struct bt_conn *conn, struct bt_conn_info *info);
struct bt_conn *bt_conn_lookup_addr_le(uint8_t id, const bt_addr_le_t *peer);
void bt_conn_unref(struct bt_conn *conn);
const bt_addr_le_t *bt_conn_get_dst(const struct bt_conn *conn);
uint16_t bt_gatt_get_mtu(struct bt_conn *conn);
int bt_gatt_notify(struct bt_conn *conn, const struct bt_gatt_attr *attr, const void *data,
                   uint16_t len);
ssize_t bt_gatt_attr_read(struct bt_conn *conn, const struct bt_gatt_attr *attr, void *buf,
                          uint16_t buf_len, uint16_t offset, const void *value,
                          uint16_t value_len);
void bt_conn_foreach(int type, void (*func)(struct bt_conn *conn, void *data), void *data);

/* ---- dt-bindings/zmk ---- */

#define HID_USAGE_KEY 0x07

#define HID_USAGE_KEY_KEYBOARD_C 0x06
#define HID_USAGE_KEY_KEYBOARD_V 0x19
#define HID_USAGE_KEY_KEYBOARD_X 0x1B
#define HID_USAGE_KEY_KEYBOARD_LEFTCONTROL 0xE0
#define HID_USAGE_KEY_KEYBOARD_RIGHT_GUI 0xE7

#define MOD_LCTL 0x01
#define MOD_LSFT 0x02
#define MOD_LALT 0x04
#define MOD_LGUI 0x08
#define MOD_RCTL 0x10
#define MOD_RSFT 0x20
#define MOD_RALT 0x40
#define MOD_RGUI 0x80

/* ---- zmk/ble.h, zmk/endpoints.h ---- */

#define ZMK_BLE_PROFILE_COUNT 5

int zmk_ble_profile_index(const bt_addr_le_t *addr);
int zmk_ble_active_profile_index(void);
bt_addr_le_t *zmk_ble_profile_address(uint8_t index);
bool zmk_ble_profile_is_connected(uint8_t index);
struct bt_conn *zmk_ble_active_profile_conn(void);

enum zmk_transport {
    ZMK_TRANSPORT_NONE = 0,
    ZMK_TRANSPORT_USB = 1,
    ZMK_TRANSPORT_BLE = 2,
};

struct zmk_endpoint_instance {
    enum zmk_transport transport;
    struct {
        int profile_index;
    } ble;
};

struct zmk_endpoint_instance zmk_endpoint_get_selected(void);
int zmk_endpoint_send_report(uint16_t usage_page);

/* ---- zmk/event_manager.h and the two events ---- */

struct zmk_event_type {
    const char *name;
};

typedef struct {
    const struct zmk_event_type *event;
} zmk_event_t;

#define ZMK_EV_EVENT_BUBBLE 0
#define ZMK_EV_EVENT_HANDLED 1
#define ZMK_EV_EVENT_CAPTURED 2

struct zmk_listener {
    int (*callback)(const zmk_event_t *eh);
};

struct zmk_event_subscription {
    const struct zmk_event_type *event_type;
    const struct zmk_listener *listener;
};

#define ZMK_LISTENER(mod, cb) const struct zmk_listener zmk_listener_##mod = {.callback = cb}
#define ZMK_SUBSCRIPTION(mod, ev_type) _Static_assert(1, "")

/* Raises an event to the listeners after `mod`. In the simulation that is
 * ZMK's HID listener, the only other party. */
int fake_raise_after(zmk_event_t *event);
#define ZMK_EVENT_RAISE_AFTER(ev, mod) fake_raise_after(&(ev).header)

struct zmk_position_state_changed {
    uint8_t source;
    uint32_t position;
    bool state;
    int64_t timestamp;
};

struct zmk_position_state_changed_event {
    zmk_event_t header;
    struct zmk_position_state_changed data;
};

struct zmk_keycode_state_changed {
    uint16_t usage_page;
    uint32_t keycode;
    uint8_t implicit_modifiers;
    uint8_t explicit_modifiers;
    bool state;
    int64_t timestamp;
};

struct zmk_keycode_state_changed_event {
    zmk_event_t header;
    struct zmk_keycode_state_changed data;
};

struct zmk_endpoint_changed {
    struct zmk_endpoint_instance endpoint;
};

struct zmk_endpoint_changed_event {
    zmk_event_t header;
    struct zmk_endpoint_changed data;
};

struct zmk_ble_active_profile_changed {
    uint8_t index;
};

struct zmk_ble_active_profile_changed_event {
    zmk_event_t header;
    struct zmk_ble_active_profile_changed data;
};

extern const struct zmk_event_type zmk_event_zmk_ble_active_profile_changed;
extern const struct zmk_event_type zmk_event_zmk_keycode_state_changed;
extern const struct zmk_event_type zmk_event_zmk_endpoint_changed;
extern const struct zmk_event_type zmk_event_zmk_position_state_changed;

static inline const struct zmk_position_state_changed *
as_zmk_position_state_changed(const zmk_event_t *eh) {
    return eh->event == &zmk_event_zmk_position_state_changed
               ? &((const struct zmk_position_state_changed_event *)eh)->data
               : NULL;
}

/* The whole event a listener was handed, recovered from its payload. */
static inline struct zmk_keycode_state_changed_event
copy_raised_zmk_keycode_state_changed(const struct zmk_keycode_state_changed *ev) {
    return *(const struct zmk_keycode_state_changed_event *)((const char *)ev -
        offsetof(struct zmk_keycode_state_changed_event, data));
}

static inline const struct zmk_keycode_state_changed *
as_zmk_keycode_state_changed(const zmk_event_t *eh) {
    return eh->event == &zmk_event_zmk_keycode_state_changed
               ? &((const struct zmk_keycode_state_changed_event *)eh)->data
               : NULL;
}

static inline const struct zmk_ble_active_profile_changed *
as_zmk_ble_active_profile_changed(const zmk_event_t *eh) {
    return eh->event == &zmk_event_zmk_ble_active_profile_changed
               ? &((const struct zmk_ble_active_profile_changed_event *)eh)->data
               : NULL;
}

static inline const struct zmk_endpoint_changed *as_zmk_endpoint_changed(const zmk_event_t *eh) {
    return eh->event == &zmk_event_zmk_endpoint_changed
               ? &((const struct zmk_endpoint_changed_event *)eh)->data
               : NULL;
}

static inline bool is_mod(uint16_t usage_page, uint32_t keycode) {
    return keycode >= HID_USAGE_KEY_KEYBOARD_LEFTCONTROL &&
           keycode <= HID_USAGE_KEY_KEYBOARD_RIGHT_GUI && usage_page == HID_USAGE_KEY;
}

/* ---- zmk/hid.h ---- */

typedef uint8_t zmk_mod_flags_t;

zmk_mod_flags_t zmk_hid_get_explicit_mods(void);
int zmk_hid_implicit_modifiers_press(zmk_mod_flags_t implicit_modifiers);
int zmk_hid_implicit_modifiers_release(void);
int zmk_hid_masked_modifiers_set(zmk_mod_flags_t masked_modifiers);
int zmk_hid_masked_modifiers_clear(void);
int zmk_hid_keyboard_press(uint32_t key);
int zmk_hid_keyboard_release(uint32_t key);
