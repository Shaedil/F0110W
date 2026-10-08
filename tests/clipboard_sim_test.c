/*
 * Copyright (c) 2026 M0110 ZMK Driver
 * SPDX-License-Identifier: MIT
 *
 * Drives the real config/clipboard/clipboard.c on a host.
 *
 * tests/fake stands in for Zephyr and ZMK. This file supplies the behaviour
 * behind it: a work queue on a virtual clock, a model of ZMK's HID report
 * state with a "host" that turns reports into the text and shortcuts a
 * computer would see, and Bluetooth connections with a scripted helper on the
 * other end. Each scenario plays a sequence of copies, profile switches and
 * key presses and checks what the host ended up seeing.
 *
 * clipboard.c is included rather than linked, so the scenarios can reset and
 * inspect its static state.
 */

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "fake/fake.h"

#include "../config/clipboard/clipboard.c"

static int failures;

#define CHECK(cond)                                                                                \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                                 \
            failures++;                                                                            \
        }                                                                                          \
    } while (0)

/* ---- Virtual clock and work queue ---- */

static int64_t now;
static struct k_work *submitted[32];
static int submitted_count;
static struct k_work_delayable *timers[16];
static int timer_count;
static int lock_depth;

/* Notifications the link will take before it reports no buffers; refilled
 * whenever the clock moves. */
static int tx_credits_per_tick = 3;
static int tx_credits;

int64_t k_uptime_get(void) { return now; }

int k_mutex_lock(struct k_mutex *mutex, k_timeout_t timeout) {
    (void)timeout;
    mutex->depth++;
    lock_depth++;
    return 0;
}

int k_mutex_unlock(struct k_mutex *mutex) {
    assert(mutex->depth > 0);
    mutex->depth--;
    lock_depth--;
    return 0;
}

int k_work_submit(struct k_work *work) {
    if (!work->pending) {
        assert(submitted_count < (int)ARRAY_SIZE(submitted));
        work->pending = true;
        submitted[submitted_count++] = work;
    }
    return 1;
}

int k_work_reschedule(struct k_work_delayable *work, k_timeout_t delay) {
    bool known = false;

    for (int i = 0; i < timer_count; i++) {
        known |= timers[i] == work;
    }
    if (!known) {
        assert(timer_count < (int)ARRAY_SIZE(timers));
        timers[timer_count++] = work;
    }

    work->due = now + (delay.ms > 0 ? delay.ms : 0);
    work->scheduled = true;
    return 1;
}

int k_work_cancel_delayable(struct k_work_delayable *work) {
    work->scheduled = false;
    return 0;
}

static void run_submitted(void) {
    while (submitted_count > 0) {
        struct k_work *work = submitted[0];

        memmove(&submitted[0], &submitted[1], sizeof(submitted[0]) * (size_t)(--submitted_count));
        work->pending = false;
        work->handler(work);
    }
}

/* Lets `ms` of virtual time pass, running everything that falls due in it. */
static void advance(int64_t ms) {
    int64_t until = now + ms;

    for (int guard = 0;; guard++) {
        assert(guard < 100000);
        run_submitted();

        struct k_work_delayable *next = NULL;
        for (int i = 0; i < timer_count; i++) {
            if (timers[i]->scheduled && timers[i]->due <= until &&
                (!next || timers[i]->due < next->due)) {
                next = timers[i];
            }
        }
        if (!next) {
            break;
        }

        if (next->due > now) {
            now = next->due;
            tx_credits = tx_credits_per_tick;
        }
        next->scheduled = false;
        next->work.handler(&next->work);
    }

    now = until;
    tx_credits = tx_credits_per_tick;
}

/* ---- Bluetooth: one connection per profile, a helper's inbox on each ---- */

struct bt_conn {
    int profile;
    bool connected;
    bool subscribed;
    uint16_t mtu;
    /* Connection interval in units of 1.25 ms; 12 is the 15 ms ZMK asks for. */
    uint16_t interval;
};

static struct bt_conn conns[ZMK_BLE_PROFILE_COUNT];
static bt_addr_le_t addresses[ZMK_BLE_PROFILE_COUNT];
/* Encrypted, but not one of the keyboard's profiles. */
static struct bt_conn stranger = {
    .profile = -1, .connected = true, .subscribed = true, .mtu = 23, .interval = 12};
static bt_addr_le_t stranger_address = {.id = 99};
static int conn_refs;

static struct {
    uint8_t frames[400][TX_FRAME_MAX];
    uint8_t lens[400];
    int count;
} inbox[ZMK_BLE_PROFILE_COUNT];

int zmk_ble_profile_index(const bt_addr_le_t *addr) {
    for (int i = 0; i < ZMK_BLE_PROFILE_COUNT; i++) {
        if (addresses[i].id == addr->id) {
            return i;
        }
    }
    return -ENODEV;
}

bt_addr_le_t *zmk_ble_profile_address(uint8_t index) { return &addresses[index]; }

struct bt_conn *bt_conn_lookup_addr_le(uint8_t id, const bt_addr_le_t *peer) {
    (void)id;
    int profile = zmk_ble_profile_index(peer);

    if (profile < 0 || !conns[profile].connected) {
        return NULL;
    }
    conn_refs++;
    return &conns[profile];
}

void bt_conn_unref(struct bt_conn *conn) {
    (void)conn;
    conn_refs--;
}

const bt_addr_le_t *bt_conn_get_dst(const struct bt_conn *conn) {
    return conn->profile < 0 ? &stranger_address : &addresses[conn->profile];
}

uint16_t bt_gatt_get_mtu(struct bt_conn *conn) { return conn->mtu; }

int bt_conn_get_info(const struct bt_conn *conn, struct bt_conn_info *info) {
    info->le.interval = conn->interval;
    return 0;
}

bool zmk_ble_profile_is_connected(uint8_t index) { return conns[index].connected; }

int bt_gatt_notify(struct bt_conn *conn, const struct bt_gatt_attr *attr, const void *data,
                   uint16_t len) {
    /* Like a HID report, a notification is never sent with the lock held. */
    assert(lock_depth == 0);
    assert(attr == &attr_zmk_clipboard_svc[4]);

    if (!conn->connected) {
        return -ENOTCONN;
    }
    if (!conn->subscribed) {
        return -EINVAL;
    }
    assert(len <= conn->mtu - 3 && len <= TX_FRAME_MAX);
    if (tx_credits == 0) {
        return -ENOMEM;
    }
    tx_credits--;

    assert(inbox[conn->profile].count < (int)ARRAY_SIZE(inbox[0].frames));
    memcpy(inbox[conn->profile].frames[inbox[conn->profile].count], data, len);
    inbox[conn->profile].lens[inbox[conn->profile].count++] = (uint8_t)len;
    return 0;
}

/* ---- ZMK's HID state, and the host reading its reports ---- */

static uint8_t explicit_mods, implicit_mods, masked_mods, mod_counts[8];
static bool keys[256];
static struct zmk_endpoint_instance selected;

static bool host_keys[256];
static uint8_t host_mods;
static char host_out[2048];
static size_t host_len;
/* Reports the host has read. */
static size_t host_reports;
/* Reports that let go of a modifier and pressed a key at once. A host may act
 * on the key first, so that Shift then still applies to it. */
static size_t host_mod_lifts_with_press;

const struct zmk_event_type zmk_event_zmk_keycode_state_changed = {"keycode"};
const struct zmk_event_type zmk_event_zmk_endpoint_changed = {"endpoint"};
const struct zmk_event_type zmk_event_zmk_position_state_changed = {"position"};
/* Only referenced by the boot-time order check, which the scenarios bypass. */
struct zmk_event_subscription __event_subscriptions_start[1];
struct zmk_event_subscription __event_subscriptions_end[1];
const struct zmk_listener zmk_listener_hid_listener;

zmk_mod_flags_t zmk_hid_get_explicit_mods(void) { return explicit_mods; }

int zmk_hid_implicit_modifiers_press(zmk_mod_flags_t mods) {
    implicit_mods = mods;
    return 0;
}

int zmk_hid_implicit_modifiers_release(void) {
    implicit_mods = 0;
    return 0;
}

int zmk_hid_masked_modifiers_set(zmk_mod_flags_t mods) {
    masked_mods = mods;
    return 0;
}

int zmk_hid_masked_modifiers_clear(void) {
    masked_mods = 0;
    return 0;
}

int zmk_hid_keyboard_press(uint32_t key) {
    keys[key] = true;
    return 0;
}

int zmk_hid_keyboard_release(uint32_t key) {
    keys[key] = false;
    return 0;
}

struct zmk_endpoint_instance zmk_endpoint_get_selected(void) { return selected; }

struct bt_conn *zmk_ble_active_profile_conn(void) {
    return bt_conn_lookup_addr_le(BT_ID_DEFAULT, &addresses[selected.ble.profile_index]);
}

static void host_append(const char *text) {
    size_t n = strlen(text);

    assert(host_len + n < sizeof(host_out));
    memcpy(&host_out[host_len], text, n + 1);
    host_len += n;
}

/* What a computer makes of a key going down: a character, or with Cmd, Ctrl
 * or Alt held, a shortcut, written as <Cmd+v>. */
static void host_key_down(uint8_t usage, uint8_t mods) {
    static const char plain[] = "abcdefghijklmnopqrstuvwxyz1234567890\n\x1b\b\t -=[]\\#;'`,./";
    static const char shifted[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%^&*()\n\x1b\b\t _+{}|#:\"~<>?";
    bool shift = mods & (MOD_LSFT | MOD_RSFT);
    char text[2] = {0};

    assert(usage >= 0x04 && usage - 0x04 < (int)sizeof(plain) - 1);

    if (!(mods & (MODS_COMMAND | MODS_ALT))) {
        text[0] = shift ? shifted[usage - 0x04] : plain[usage - 0x04];
        host_append(text);
        return;
    }

    host_append("<");
    if (mods & (MOD_LGUI | MOD_RGUI)) {
        host_append("Cmd+");
    }
    if (mods & (MOD_LCTL | MOD_RCTL)) {
        host_append("Ctrl+");
    }
    if (mods & MODS_ALT) {
        host_append("Alt+");
    }
    if (shift) {
        host_append("Shift+");
    }
    text[0] = plain[usage - 0x04];
    host_append(text);
    host_append(">");
}

int zmk_endpoint_send_report(uint16_t usage_page) {
    assert(usage_page == HID_USAGE_KEY);
    assert(lock_depth == 0);

    uint8_t mods = (uint8_t)((explicit_mods & ~masked_mods) | implicit_mods);

    host_reports++;
    for (int usage = 0; usage < 256; usage++) {
        if (keys[usage] && !host_keys[usage] && !is_mod(HID_USAGE_KEY, (uint32_t)usage)) {
            host_key_down((uint8_t)usage, mods);
            if (host_mods & ~mods) {
                host_mod_lifts_with_press++;
            }
        }
        host_keys[usage] = keys[usage];
    }
    host_mods = mods;
    return 0;
}

/* ZMK's own HID listener, which gets every key event the clipboard listener
 * lets through. Mirrors zmk/app/src/hid_listener.c, including the way a real
 * key event overwrites the implicit modifiers. */
static void hid_listener(const struct zmk_keycode_state_changed *ev) {
    int mod = (int)ev->keycode - HID_USAGE_KEY_KEYBOARD_LEFTCONTROL;

    if (ev->state) {
        if (is_mod(ev->usage_page, ev->keycode)) {
            mod_counts[mod]++;
            explicit_mods |= (uint8_t)BIT(mod);
        } else {
            keys[ev->keycode] = true;
        }
        implicit_mods = ev->implicit_modifiers;
    } else {
        if (is_mod(ev->usage_page, ev->keycode)) {
            if (mod_counts[mod] && --mod_counts[mod] == 0) {
                explicit_mods &= (uint8_t)~BIT(mod);
            }
        } else {
            keys[ev->keycode] = false;
        }
        implicit_mods = 0;
    }
    zmk_endpoint_send_report(HID_USAGE_KEY);
}

int fake_raise_after(zmk_event_t *event) {
    const struct zmk_keycode_state_changed *ev = as_zmk_keycode_state_changed(event);

    assert(ev && lock_depth == 0);
    hid_listener(ev);
    return 0;
}

/* ---- The user ---- */

#define KEY_ENTER 0x28
#define KEY_ESC 0x29
#define KEY_LCTRL 0xE0
#define KEY_LALT 0xE2
#define KEY_LGUI 0xE3

static int64_t event_seq;

/* A key on the matrix changing state: the position event, and, unless it is a
 * layer key, the keycode event the keymap turns it into. As in ZMK, the
 * keycode carries the timestamp of the press it came from. */
static void matrix_key(uint32_t usage, bool down, bool has_keycode) {
    struct zmk_position_state_changed_event position = {
        .header = {.event = &zmk_event_zmk_position_state_changed},
        .data = {.position = usage, .state = down, .timestamp = ++event_seq},
    };
    struct zmk_keycode_state_changed_event ev = {
        .header = {.event = &zmk_event_zmk_keycode_state_changed},
        .data = {.usage_page = HID_USAGE_KEY,
                 .keycode = usage,
                 .state = down,
                 .timestamp = position.data.timestamp},
    };

    CHECK(clipboard_listener(&position.header) == ZMK_EV_EVENT_BUBBLE);

    if (has_keycode && clipboard_listener(&ev.header) == ZMK_EV_EVENT_BUBBLE) {
        hid_listener(&ev.data);
    }
}

static void key(uint32_t usage, bool down) { matrix_key(usage, down, true); }

/* The key that reaches the layer with the profile keys on it: no keycode. */
#define LAYER_KEY 0xF0
static void layer_key(bool down) { matrix_key(LAYER_KEY, down, false); }

/* Holds `mod`, taps `usage`, lets go, the way a person presses a shortcut. */
static void chord(uint32_t mod, uint32_t usage) {
    key(mod, true);
    advance(30);
    key(usage, true);
    advance(60);
    key(usage, false);
    advance(25);
    key(mod, false);
}

static void select_endpoint(enum zmk_transport transport, int profile) {
    struct zmk_endpoint_changed_event ev = {
        .header = {.event = &zmk_event_zmk_endpoint_changed},
    };

    selected.transport = transport;
    selected.ble.profile_index = profile;
    ev.data.endpoint = selected;
    clipboard_listener(&ev.header);
}

/* ---- The helper on a computer ---- */

static ssize_t helper_write_as(struct bt_conn *conn, const uint8_t *frame, size_t len) {
    return rx_write(conn, &attr_zmk_clipboard_svc[2], frame, (uint16_t)len, 0, 0);
}

static void helper_write(int profile, const uint8_t *frame, size_t len) {
    CHECK(helper_write_as(&conns[profile], frame, len) == (ssize_t)len);
}

static void helper_hello(int profile) {
    const uint8_t hello[] = {CLIP_FRAME_HELLO, CLIP_PROTO_VERSION, 0};

    conns[profile].subscribed = true;
    helper_write(profile, hello, sizeof(hello));
}

static void helper_copy_bytes(int profile, const uint8_t *text, uint16_t len, uint8_t flags,
                              uint32_t crc) {
    uint8_t frame[20];
    uint16_t offset = 0;
    uint16_t taken;

    helper_write(profile, frame, clip_encode_begin(frame, flags, len, crc));
    while (offset < len) {
        size_t n = clip_encode_data(frame, sizeof(frame), text, len, offset, &taken);

        helper_write(profile, frame, n);
        offset = (uint16_t)(offset + taken);
    }
    frame[0] = CLIP_FRAME_END;
    helper_write(profile, frame, 1);
}

/* A copy on that computer, with the keyboard not on its USB port. */
static void helper_copy(int profile, const char *text) {
    uint16_t len = (uint16_t)strlen(text);

    helper_copy_bytes(profile, (const uint8_t *)text, len, CLIP_FLAG_USB_KNOWN,
                      clip_crc32((const uint8_t *)text, len));
}

/* A helper from before opaque clips existed. */
static void helper_hello_v1(int profile) {
    const uint8_t hello[] = {CLIP_FRAME_HELLO, 1, 0};

    conns[profile].subscribed = true;
    helper_write(profile, hello, sizeof(hello));
}

/* A message for the helper on another computer, not text. */
static void helper_copy_opaque(int profile, const uint8_t *bytes, uint16_t len) {
    helper_copy_bytes(profile, bytes, len, CLIP_FLAG_USB_KNOWN | CLIP_FLAG_OPAQUE,
                      clip_crc32(bytes, len));
}

static void helper_hold(int profile, uint8_t flags) {
    const uint8_t hold[] = {CLIP_FRAME_HOLD, flags};

    helper_write(profile, hold, sizeof(hold));
}

static void helper_relay(int profile, const char *text) {
    uint8_t frame[1 + 96] = {CLIP_FRAME_RELAY};
    size_t len = strlen(text);

    assert(len < sizeof(frame));
    memcpy(&frame[1], text, len);
    helper_write(profile, frame, 1 + len);
}

/* Whether the helper on `profile` has been passed exactly this datagram. */
static bool helper_got_relay(int profile, const char *text) {
    size_t len = strlen(text);

    for (int i = 0; i < inbox[profile].count; i++) {
        if (inbox[profile].frames[i][0] == CLIP_FRAME_RELAY &&
            inbox[profile].lens[i] == 1 + len &&
            memcmp(&inbox[profile].frames[i][1], text, len) == 0) {
            return true;
        }
    }
    return false;
}

static void helper_ack(int profile, uint32_t crc) {
    const uint8_t ack[] = {CLIP_FRAME_ACK, (uint8_t)crc, (uint8_t)(crc >> 8), (uint8_t)(crc >> 16),
                           (uint8_t)(crc >> 24)};

    helper_write(profile, ack, sizeof(ack));
}

/* Reassembles the clip notified to the helper on `profile`, if a whole one
 * has arrived, and empties its inbox. */
static bool helper_received(int profile, char *text, size_t text_cap, uint32_t *crc) {
    static uint8_t buf[CLIP_BUF_LEN];
    struct clip_rx rx;
    bool complete = false;

    clip_rx_init(&rx, buf, sizeof(buf));
    for (int i = 0; i < inbox[profile].count; i++) {
        const uint8_t *frame = inbox[profile].frames[i];
        size_t len = inbox[profile].lens[i];
        struct clip_begin begin;
        uint16_t offset;
        const uint8_t *payload;

        if (clip_parse_begin(frame, len, &begin)) {
            clip_rx_begin(&rx, &begin);
        } else if (frame[0] == CLIP_FRAME_DATA) {
            int n = clip_parse_data(frame, len, &offset, &payload);

            clip_rx_data(&rx, offset, payload, (size_t)n);
        } else if (frame[0] == CLIP_FRAME_END) {
            complete = clip_rx_end(&rx) == CLIP_RESULT_OK;
            if (complete) {
                assert(rx.expected < text_cap);
                memcpy(text, buf, rx.expected);
                text[rx.expected] = '\0';
                *crc = rx.crc;
            }
        }
    }

    inbox[profile].count = 0;
    return complete;
}

/* The first frame of `type` in the helper's inbox, or NULL. */
static const uint8_t *helper_frame(int profile, uint8_t type) {
    for (int i = 0; i < inbox[profile].count; i++) {
        if (inbox[profile].frames[i][0] == type) {
            return inbox[profile].frames[i];
        }
    }
    return NULL;
}

static bool helper_got_unreachable(int profile) {
    const uint8_t *answer = helper_frame(profile, CLIP_FRAME_RESULT);

    return answer && answer[1] == CLIP_RESULT_UNREACHABLE;
}

/* ---- Scenario plumbing ---- */

/* Back to a keyboard that has just booted, paired on every profile, with
 * profile 0 selected and nobody subscribed. */
static void reset(void) {
    memset(&clip, 0, sizeof(clip));
    clip_rx_init(&clip.rx, clip.buf, sizeof(clip.buf));
    clip.requester = -1;
    helpers = 0;
    helpers_opaque = 0;
    memset(&relay, 0, sizeof(relay));
    memset(&fetch, 0, sizeof(fetch));
    rx_seen = 0;
    status_owed = 0;
    poke_owed = 0;
    memset(&expected, 0, sizeof(expected));
    memset(&stopper, 0, sizeof(stopper));
    held_count = 0;
    memset(&result, 0, sizeof(result));
    memset(&delivery, 0, sizeof(delivery));
    memset(&pending_paste, 0, sizeof(pending_paste));
    memset(&job, 0, sizeof(job));
    memset(swallowed, 0, sizeof(swallowed));
    intercept_ok = true;

    submitted_count = 0;
    evaluate_work.pending = false;
    for (int i = 0; i < timer_count; i++) {
        timers[i]->scheduled = false;
    }

    explicit_mods = implicit_mods = masked_mods = 0;
    memset(mod_counts, 0, sizeof(mod_counts));
    memset(keys, 0, sizeof(keys));
    memset(host_keys, 0, sizeof(host_keys));
    host_mods = 0;
    host_len = 0;
    host_out[0] = '\0';
    host_reports = 0;
    host_mod_lifts_with_press = 0;

    for (int i = 0; i < ZMK_BLE_PROFILE_COUNT; i++) {
        addresses[i].id = (uint8_t)(i + 1);
        conns[i] = (struct bt_conn){.profile = i, .connected = true, .mtu = 23, .interval = 12};
        inbox[i].count = 0;
    }
    selected = (struct zmk_endpoint_instance){.transport = ZMK_TRANSPORT_BLE};
    tx_credits_per_tick = 3;
    tx_credits = tx_credits_per_tick;
}

/* Nothing left half-done: no job, no key or modifier the user is not holding,
 * no mask, no lock, no leaked connection reference. */
static void check_idle(const char *scenario) {
    bool stuck = false;

    for (int usage = 0; usage < 256; usage++) {
        stuck |= keys[usage];
    }
    if (job.kind != JOB_NONE || stuck || explicit_mods || implicit_mods || masked_mods ||
        pending_paste.active || held_count || lock_depth || conn_refs || swallowed[0] ||
        swallowed[1] || swallowed[2] || swallowed[3]) {
        printf("FAIL %s: not idle (job %d keys %d mods %02x/%02x/%02x pending %d held %d lock %d "
               "refs %d)\n",
               scenario, job.kind, stuck, explicit_mods, implicit_mods, masked_mods,
               pending_paste.active, held_count, lock_depth, conn_refs);
        failures++;
    }
    if (host_mod_lifts_with_press) {
        printf("FAIL %s: %zu report(s) let go of a modifier while pressing a key\n", scenario,
               host_mod_lifts_with_press);
        failures++;
    }
}

static void expect_host(const char *scenario, const char *expected) {
    if (strcmp(host_out, expected) != 0) {
        printf("FAIL %s: host saw \"%s\", want \"%s\"\n", scenario, host_out, expected);
        failures++;
    }
    check_idle(scenario);
}

static void clear_host(void) {
    host_len = 0;
    host_out[0] = '\0';
}

/* A clip copied on profile 0, whose computer runs a helper. */
static void copy_on_profile_0(const char *text) {
    helper_hello(0);
    advance(10);
    helper_copy(0, text);
    advance(10);
}

/* ---- Scenarios ---- */

static void test_types_on_a_bare_host(void) {
    const char *text = "Hello, World! (1+1=2) ~/x_y.txt\n";

    reset();
    copy_on_profile_0(text);
    CHECK(clip.valid);

    const uint8_t *status = helper_frame(0, CLIP_FRAME_STATUS);
    const uint8_t *answer = helper_frame(0, CLIP_FRAME_RESULT);
    CHECK(status && status[1] == CLIP_PROTO_VERSION);
    CHECK(status && (status[2] | status[3] << 8) == CONFIG_ZMK_CLIPBOARD_MAX_LEN);
    CHECK(answer && answer[1] == CLIP_RESULT_OK);

    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    advance(50);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(3000);
    expect_host("typed on a bare host", text);

    /* The clip is still the newest copy, so a second paste types it again. */
    clear_host();
    chord(KEY_LCTRL, HID_USAGE_KEY_KEYBOARD_V);
    advance(3000);
    expect_host("typed again, with Ctrl", text);
}

static void test_held_modifier_never_leaks(void) {
    const char *text = "quit window all";

    reset();
    copy_on_profile_0(text);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);

    /* Cmd and V stay down for the whole of the typing and beyond. */
    key(KEY_LGUI, true);
    advance(20);
    key(HID_USAGE_KEY_KEYBOARD_V, true);
    advance(3000);
    CHECK(strcmp(host_out, text) == 0);
    key(HID_USAGE_KEY_KEYBOARD_V, false);
    advance(20);
    key(KEY_LGUI, false);
    advance(20);
    expect_host("modifier held throughout", text);

    /* Let go of Cmd in the middle of a character instead. */
    clear_host();
    key(KEY_LGUI, true);
    advance(20);
    key(HID_USAGE_KEY_KEYBOARD_V, true);
    advance(12 * 5);
    key(KEY_LGUI, false);
    advance(7);
    key(HID_USAGE_KEY_KEYBOARD_V, false);
    advance(3000);
    expect_host("modifier released mid-character", text);
}

static void test_paste_on_the_origin_is_left_alone(void) {
    reset();
    copy_on_profile_0("stays put");
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(1000);
    expect_host("paste where it was copied", "<Cmd+v>");
}

static void test_delivers_to_a_helper(void) {
    const char *text = "caf\xC3\xA9 \xE2\x80\x9Cquoted\xE2\x80\x9D \xF0\x9F\x98\x80";
    char got[CONFIG_ZMK_CLIPBOARD_MAX_LEN];
    uint32_t crc = 0;

    reset();
    copy_on_profile_0(text);
    helper_hello(1);
    advance(500);

    /* Nothing leaves for another computer until the keyboard is switched to
     * it; all the helper there has had is the answer to its HELLO. */
    CHECK(helper_frame(1, CLIP_FRAME_STATUS) != NULL);
    CHECK(helper_frame(1, CLIP_FRAME_BEGIN) == NULL);

    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    advance(500);
    CHECK(helper_received(1, got, sizeof(got), &crc));
    CHECK(strcmp(got, text) == 0);

    helper_ack(1, crc);
    advance(10);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(3000);
    /* Every byte made it, and the paste is the computer's own. */
    expect_host("delivered to a helper", "<Cmd+v>");

    /* It is not sent twice. */
    select_endpoint(ZMK_TRANSPORT_BLE, 0);
    advance(100);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    advance(500);
    CHECK(helper_frame(1, CLIP_FRAME_BEGIN) == NULL);
}

static void test_paste_waits_for_the_helper(void) {
    char got[CONFIG_ZMK_CLIPBOARD_MAX_LEN];
    uint32_t crc = 0;

    reset();
    copy_on_profile_0("in flight");
    helper_hello(1);
    advance(10);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);

    /* Paste lands before the helper has acknowledged. */
    advance(2);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    CHECK(host_len == 0);
    advance(200);
    CHECK(helper_received(1, got, sizeof(got), &crc));
    helper_ack(1, crc);
    advance(100);
    /* Cmd was let go long ago; the paste still goes out as Cmd-V, once. */
    expect_host("paste held for the helper", "<Cmd+v>");

    advance(3000);
    expect_host("and nothing typed afterwards", "<Cmd+v>");
}

static void test_silent_helper_falls_back_to_typing(void) {
    const char *text = "typed after all";

    reset();
    copy_on_profile_0(text);
    helper_hello(1);
    advance(10);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    advance(300);

    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(CONFIG_ZMK_CLIPBOARD_ACK_WAIT_MS - 200);
    CHECK(host_len == 0);
    advance(3000);
    expect_host("helper never acknowledged", text);

    /* Having been let down once, the keyboard does not wait again. */
    clear_host();
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    CHECK(host_len > 0);
    advance(3000);
    expect_host("no second wait", text);

    /* A HELLO restores it, and the clip is offered afresh. */
    inbox[1].count = 0;
    helper_hello(1);
    advance(300);
    CHECK(helper_frame(1, CLIP_FRAME_BEGIN) != NULL);
}

static void test_expiry_wipes_the_clip(void) {
    reset();
    copy_on_profile_0("short-lived secret");
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    advance((int64_t)CONFIG_ZMK_CLIPBOARD_TTL_SEC * 1000 + 1);

    CHECK(!clip.valid);
    for (size_t i = 0; i < sizeof(clip.buf); i++) {
        if (clip.buf[i] != 0) {
            CHECK(!"clip text left in memory after expiry");
            break;
        }
    }

    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(1000);
    expect_host("paste after expiry", "<Cmd+v>");
}

static void test_copy_elsewhere_makes_the_clip_stale(void) {
    reset();
    copy_on_profile_0("older");
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    advance(20);

    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_C);
    advance(20);
    CHECK(!clip.valid);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(1000);
    expect_host("copy on the other computer", "<Cmd+c><Cmd+v>");

    /* A copy on the clip's own computer is that helper's business: the clip
     * stays, and the helper is prodded to look at its clipboard now. */
    reset();
    copy_on_profile_0("kept");
    inbox[0].count = 0;
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_C);
    advance(20);
    CHECK(clip.valid);
    CHECK(helper_frame(0, CLIP_FRAME_POKE) != NULL);

    /* Unless that helper has gone, in which case nobody will say what the
     * copy was and the clip can only be stale. */
    helper_write(0, (const uint8_t[]){CLIP_FRAME_BYE}, 1);
    advance(20);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_C);
    advance(20);
    CHECK(!clip.valid);
}

static void test_any_key_stops_the_typing(void) {
    const char *text = "a long clip going into the wrong window entirely";

    reset();
    copy_on_profile_0(text);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(100);

    key(KEY_ESC, true);
    advance(40);
    key(KEY_ESC, false);
    advance(3000);

    CHECK(host_len > 0 && host_len < strlen(text));
    CHECK(strncmp(host_out, text, host_len) == 0);
    check_idle("stopped by a key");
}

static void test_new_clip_replaces_one_being_typed(void) {
    const char *old = "the previous clip, still being typed out";

    reset();
    copy_on_profile_0(old);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(100);

    helper_copy(0, "new");
    advance(3000);
    CHECK(host_len < strlen(old) && strncmp(host_out, old, host_len) == 0);
    check_idle("replaced mid-typing");

    clear_host();
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(3000);
    expect_host("the new clip", "new");
}

static void test_switching_away_stops_the_typing(void) {
    const char *text = "meant for the computer just left";

    reset();
    copy_on_profile_0(text);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(100);
    size_t typed = host_len;

    select_endpoint(ZMK_TRANSPORT_BLE, 2);
    advance(3000);
    CHECK(typed > 0 && host_len == typed);
    check_idle("switched away mid-typing");

    /* A paste that was waiting on a helper is dropped the same way. */
    reset();
    copy_on_profile_0("waiting");
    helper_hello(1);
    advance(10);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    select_endpoint(ZMK_TRANSPORT_BLE, 2);
    advance(3000);
    expect_host("switched away while waiting", "");
}

static void test_usb(void) {
    const uint8_t text[] = "over the wire";
    const uint16_t len = sizeof(text) - 1;
    const struct {
        uint8_t flags;
        const char *expected;
    } cases[] = {
        /* The USB port leads to another computer: type. */
        {CLIP_FLAG_USB_KNOWN, "over the wire"},
        /* It leads back to the computer the clip came from: leave alone. */
        {CLIP_FLAG_USB_KNOWN | CLIP_FLAG_USB_LOCAL, "<Cmd+v>"},
        /* Unknown: leave alone rather than risk typing a clipboard back at
         * its own computer. */
        {0, "<Cmd+v>"},
    };

    for (size_t i = 0; i < ARRAY_SIZE(cases); i++) {
        reset();
        helper_hello(0);
        helper_copy_bytes(0, text, len, cases[i].flags, clip_crc32(text, len));
        advance(10);
        select_endpoint(ZMK_TRANSPORT_USB, 0);
        chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
        advance(3000);
        expect_host("paste over USB", cases[i].expected);
    }
}

static void test_helper_disconnects(void) {
    const char *text = "nobody home";

    reset();
    copy_on_profile_0(text);
    helper_hello(1);
    advance(10);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    advance(300);

    /* The helper's computer drops off and comes back with no helper running. */
    conns[1].connected = false;
    on_disconnected(&conns[1], 0);
    advance(50);
    conns[1] = (struct bt_conn){.profile = 1, .connected = true, .mtu = 23, .interval = 12};

    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    CHECK(host_len > 0);
    advance(3000);
    expect_host("after the helper went away", text);
}

static void test_delivery_survives_a_busy_link(void) {
    char text[CONFIG_ZMK_CLIPBOARD_MAX_LEN];
    char got[CONFIG_ZMK_CLIPBOARD_MAX_LEN + 1];
    uint32_t crc = 0;

    for (size_t i = 0; i < sizeof(text) - 1; i++) {
        text[i] = (char)('a' + i % 26);
    }
    text[sizeof(text) - 1] = '\0';

    reset();
    copy_on_profile_0(text);
    helper_hello(1);
    advance(10);

    /* One notification at a time, with a buffer shortage after each. */
    tx_credits_per_tick = 1;
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    advance(5000);
    CHECK(helper_received(1, got, sizeof(got), &crc));
    CHECK(strcmp(got, text) == 0);
    check_idle("slow link");

    /* A wider MTU carries it in fewer, larger frames. */
    reset();
    copy_on_profile_0(text);
    helper_hello(1);
    conns[1].mtu = 247;
    advance(10);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    advance(500);
    int frames = inbox[1].count;
    CHECK(helper_received(1, got, sizeof(got), &crc));
    CHECK(strcmp(got, text) == 0);
    CHECK(frames < 8);
}

static void test_bad_clips_are_refused(void) {
    uint8_t big[CONFIG_ZMK_CLIPBOARD_MAX_LEN + 1];
    const uint8_t *answer;

    memset(big, 'x', sizeof(big));

    /* Too long: refused, and the older clip does not survive it either. */
    reset();
    copy_on_profile_0("older");
    inbox[0].count = 0;
    helper_copy_bytes(0, big, sizeof(big), CLIP_FLAG_USB_KNOWN, clip_crc32(big, sizeof(big)));
    advance(10);
    answer = helper_frame(0, CLIP_FRAME_RESULT);
    CHECK(answer && answer[1] == CLIP_RESULT_TOO_LONG);
    CHECK(!clip.valid);

    /* Damaged in transit. */
    reset();
    helper_hello(0);
    helper_copy_bytes(0, big, 40, CLIP_FLAG_USB_KNOWN, 0xDEADBEEF);
    advance(10);
    answer = helper_frame(0, CLIP_FRAME_RESULT);
    CHECK(answer && answer[1] == CLIP_RESULT_CORRUPT);
    CHECK(!clip.valid && clip.buf[0] == 0);

    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(1000);
    expect_host("nothing to carry", "<Cmd+v>");

    /* The helper says its newest copy cannot be carried. */
    reset();
    copy_on_profile_0("older");
    helper_write(0, (const uint8_t[]){CLIP_FRAME_CLEAR}, 1);
    advance(10);
    CHECK(!clip.valid);
}

static void test_only_profiles_may_write(void) {
    uint8_t frame[CLIP_BEGIN_LEN];
    size_t len = clip_encode_begin(frame, 0, 4, 0);

    reset();
    copy_on_profile_0("mine");
    CHECK(helper_write_as(&stranger, frame, len) == BT_GATT_ERR(BT_ATT_ERR_WRITE_NOT_PERMITTED));
    CHECK(helper_write_as(&conns[0], frame, 0) == BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN));
    advance(10);
    CHECK(clip.valid);
}

static void test_other_shortcuts_pass(void) {
    reset();
    copy_on_profile_0("untouched");
    select_endpoint(ZMK_TRANSPORT_BLE, 1);

    /* Cmd-Opt-V is not paste. */
    key(KEY_LGUI, true);
    key(KEY_LALT, true);
    key(HID_USAGE_KEY_KEYBOARD_V, true);
    advance(50);
    key(HID_USAGE_KEY_KEYBOARD_V, false);
    key(KEY_LALT, false);
    key(KEY_LGUI, false);
    /* Neither is a bare v. */
    key(HID_USAGE_KEY_KEYBOARD_V, true);
    advance(50);
    key(HID_USAGE_KEY_KEYBOARD_V, false);
    advance(1000);
    expect_host("not a paste", "<Cmd+Alt+v>v");
}

static void test_typographic_text(void) {
    reset();
    copy_on_profile_0("it\xE2\x80\x99s \xE2\x80\x9C" "fine\xE2\x80\x9D\xE2\x80\xA6\r\nna\xC3\xAFve");
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(3000);
    expect_host("typographic punctuation", "it's \"fine\"...\nnaive");
}

static void test_typing_takes_a_report_per_character(void) {
    /* No key twice in a row and no Shift to let go of, so each character
     * lets go of the last one in the report that presses it. */
    const char *text = "the quick brown fox";
    size_t before;

    reset();
    copy_on_profile_0(text);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    key(KEY_LGUI, true);
    advance(20);
    before = host_reports;
    key(HID_USAGE_KEY_KEYBOARD_V, true);
    advance(3000);
    /* A report per character, plus one putting the mask on and one letting
     * everything go. */
    CHECK(host_reports - before == strlen(text) + 2);
    key(HID_USAGE_KEY_KEYBOARD_V, false);
    advance(20);
    key(KEY_LGUI, false);
    advance(20);
    expect_host("a report per character", text);
}

static void test_typing_lets_go_where_it_has_to(void) {
    /* A key twice in a row has to come up in between, and Shift has to come
     * up in a report of its own, before the key that follows it goes down. */
    const char *text = "Hello, Mississippi!! aA Aa \"Q\"...ok\n";

    reset();
    copy_on_profile_0(text);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(5000);
    expect_host("repeats and Shift", text);
}

static void test_without_intercept(void) {
    /* What is left if the listener ended up behind ZMK's HID listener: no
     * typing, since the paste has already gone out by then. */
    reset();
    intercept_ok = false;
    copy_on_profile_0("never typed");
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(3000);
    expect_host("intercept unavailable", "<Cmd+v>");
}


static void test_keys_behind_a_waiting_paste_keep_their_place(void) {
    char got[CONFIG_ZMK_CLIPBOARD_MAX_LEN];
    uint32_t crc = 0;

    /* Paste, then Enter straight after, while the helper has yet to
     * acknowledge. Enter must not get to the host first. */
    reset();
    copy_on_profile_0("submitted");
    helper_hello(1);
    advance(10);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    advance(2);

    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    key(KEY_ENTER, true);
    advance(30);
    key(KEY_ENTER, false);
    CHECK(host_len == 0);

    advance(100);
    CHECK(helper_received(1, got, sizeof(got), &crc));
    helper_ack(1, crc);
    advance(200);
    expect_host("paste then Enter, with a helper", "<Cmd+v>\n");

    /* The same when the helper never answers and the clip is typed. */
    reset();
    copy_on_profile_0("submitted");
    helper_hello(1);
    advance(10);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    advance(300);

    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    key(KEY_ENTER, true);
    advance(30);
    key(KEY_ENTER, false);
    advance(3000);
    expect_host("paste then Enter, typed", "submitted\n");

    /* A shifted letter typed behind the paste keeps its Shift. */
    reset();
    copy_on_profile_0("x");
    helper_hello(1);
    advance(10);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    advance(300);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    chord(0xE1 /* left shift */, 0x04 /* a */);
    advance(3000);
    expect_host("shifted key behind a paste", "xA");
}

static void test_fast_switch_waits_for_the_new_clip(void) {
    /* Copy, switch and paste faster than the helper reports the copy. The
     * paste must carry the new clip, not the one from before. */
    reset();
    copy_on_profile_0("old");
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_C);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(100);
    CHECK(strcmp(host_out, "<Cmd+c>") == 0);

    helper_copy(0, "new");
    advance(3000);
    expect_host("clip arrived after the paste", "<Cmd+c>new");

    /* With nothing held at all before the copy. */
    reset();
    helper_hello(0);
    advance(10);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_C);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(200);
    helper_copy(0, "first");
    advance(3000);
    expect_host("first clip arrived after the paste", "<Cmd+c>first");

    /* The shortcut copied nothing, as Ctrl-C in a terminal does. After a
     * moment the paste goes ahead with the clip there is. */
    reset();
    copy_on_profile_0("still good");
    chord(KEY_LCTRL, HID_USAGE_KEY_KEYBOARD_C);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(3000);
    expect_host("the copy changed nothing", "<Ctrl+c>still good");

    /* The helper says the copy cannot be carried. */
    reset();
    copy_on_profile_0("old");
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_C);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(100);
    helper_write(0, (const uint8_t[]){CLIP_FRAME_CLEAR}, 1);
    advance(3000);
    expect_host("the copy cannot be carried", "<Cmd+c><Cmd+v>");

    /* The transfer starts and then stalls. The paste does not wait on it
     * for ever; it goes ahead as the computer's own. */
    reset();
    helper_hello(0);
    advance(10);
    uint8_t begin[CLIP_BEGIN_LEN];
    helper_write(0, begin, clip_encode_begin(begin, CLIP_FLAG_USB_KNOWN, 50, 0x1234));
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    CHECK(host_len == 0);
    advance(CONFIG_ZMK_CLIPBOARD_ACK_WAIT_MS + 100);
    expect_host("the transfer stalled", "<Cmd+v>");

    /* Long after the copy shortcut, nothing waits. */
    reset();
    copy_on_profile_0("old");
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_C);
    advance(5000);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    clear_host();
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    CHECK(host_len > 0);
    advance(3000);
    expect_host("no wait once the helper has had its time", "old");
}

static void test_layer_key_stops_a_job_before_a_switch(void) {
    reset();
    copy_on_profile_0("a clip long enough to still be going when the switch comes");
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);

    /* Step through the typing a millisecond at a time and press the layer key
     * at each point of a character: no key may be left down for the old
     * computer when the profile changes next. */
    for (int phase = 0; phase < 30; phase++) {
        advance(1);
        if (phase < 24) {
            continue;
        }
        layer_key(true);
        bool down = false;
        for (int usage = 0; usage < 256; usage++) {
            down |= keys[usage] || host_keys[usage];
        }
        CHECK(!down);
        CHECK(job.kind == JOB_NONE && masked_mods == 0);
        layer_key(false);
    }

    size_t typed = host_len;
    select_endpoint(ZMK_TRANSPORT_BLE, 2);
    advance(3000);
    CHECK(host_len == typed);
    check_idle("layer key before a switch");
}

static void test_expiry_lets_typing_finish(void) {
    char text[200];

    memset(text, 'z', sizeof(text) - 1);
    text[sizeof(text) - 1] = '\0';

    reset();
    copy_on_profile_0(text);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    /* Paste a second before the clip is due to be wiped; typing it takes
     * several. */
    advance((int64_t)CONFIG_ZMK_CLIPBOARD_TTL_SEC * 1000 - 1000);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(20000);
    expect_host("expiry during typing", text);
    /* And then it is wiped. */
    CHECK(!clip.valid && clip.buf[0] == 0);
}

static void test_late_expiry_spares_a_newer_clip(void) {
    reset();
    copy_on_profile_0("first");
    /* The expiry of the first clip has come due but not run when its
     * replacement lands. */
    now += (int64_t)CONFIG_ZMK_CLIPBOARD_TTL_SEC * 1000;
    helper_copy(0, "second");
    expire_work.scheduled = false;
    expire(&expire_work.work);
    advance(10);
    CHECK(clip.valid && clip.len == 6);
}

static void test_untypable_clip_is_not_swallowed(void) {
    char got[CONFIG_ZMK_CLIPBOARD_MAX_LEN];
    uint32_t crc = 0;
    const char *text = "\xE6\x97\xA5\xE6\x9C\xAC\xE8\xAA\x9E";

    /* Nothing in it has a key, so on a computer without a helper the paste is
     * left to the host rather than eaten. */
    reset();
    copy_on_profile_0(text);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(3000);
    expect_host("nothing typable", "<Cmd+v>");

    /* A helper still gets it whole. */
    helper_hello(2);
    advance(10);
    select_endpoint(ZMK_TRANSPORT_BLE, 2);
    advance(500);
    CHECK(helper_received(2, got, sizeof(got), &crc) && strcmp(got, text) == 0);
}

static void test_replies_survive_a_full_link(void) {
    reset();
    tx_credits_per_tick = 0;
    tx_credits = 0;
    helper_hello(0);
    helper_copy(0, "x");
    advance(100);
    CHECK(inbox[0].count == 0);

    tx_credits_per_tick = 3;
    advance(100);
    CHECK(helper_frame(0, CLIP_FRAME_STATUS) != NULL);
    CHECK(helper_frame(0, CLIP_FRAME_RESULT) != NULL);
}

static void test_slow_link_paces_the_typing(void) {
    const char *text = "paced by the link";

    /* A 50 ms connection interval: a report per interval, not per 12 ms. The
     * paste goes down 335 ms before the check, room for six reports. */
    reset();
    copy_on_profile_0(text);
    conns[1].interval = 40;
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(250);
    CHECK(host_len >= 3 && host_len <= 7);
    advance(3000);
    expect_host("slow link", text);
}

static void test_forgets_a_profile_that_went_away(void) {
    char got[CONFIG_ZMK_CLIPBOARD_MAX_LEN];
    uint32_t crc = 0;

    reset();
    copy_on_profile_0("delivered once");
    helper_hello(1);
    advance(10);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    advance(300);
    CHECK(helper_received(1, got, sizeof(got), &crc));
    helper_ack(1, crc);
    advance(10);
    CHECK(clip.delivered & BIT(1));

    /* The bond is cleared: the connection drops and its address no longer
     * maps to the profile. A different computer pairs in its place. */
    conns[1].connected = false;
    addresses[1].id = 0;
    on_disconnected(&conns[1], 0);
    advance(10);
    CHECK(!(helpers & BIT(1)) && !(clip.delivered & BIT(1)));

    addresses[1].id = 42;
    conns[1] = (struct bt_conn){.profile = 1, .connected = true, .mtu = 23, .interval = 12};
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(3000);
    expect_host("a new computer on the profile", "delivered once");
}

/* An opaque clip that happens to be made of typable characters, so that
 * typing it would show. */
static const char ticket[] = "fetch it from 10.0.0.7";
#define TICKET_LEN ((uint16_t)(sizeof(ticket) - 1))

/* The ticket copied on profile 0, a helper that understands it on profile 1,
 * and the keyboard switched there and the ticket handed over. Returns its
 * checksum. */
static uint32_t ticket_delivered_to_profile_1(void) {
    char got[CLIP_BUF_LEN + 1];
    uint32_t crc = 0;

    helper_hello(0);
    advance(10);
    helper_copy_opaque(0, (const uint8_t *)ticket, TICKET_LEN);
    helper_hello(1);
    advance(10);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    advance(300);

    const uint8_t *begin = helper_frame(1, CLIP_FRAME_BEGIN);
    CHECK(begin && (begin[1] & CLIP_FLAG_OPAQUE));
    CHECK(helper_received(1, got, sizeof(got), &crc));
    CHECK(strcmp(got, ticket) == 0);
    return crc;
}

static void test_opaque_clip_is_never_typed(void) {
    reset();
    helper_hello(0);
    advance(10);
    helper_copy_opaque(0, (const uint8_t *)ticket, TICKET_LEN);
    advance(10);
    CHECK(clip.valid && clip.opaque && !clip.typable);

    const uint8_t *status = helper_frame(0, CLIP_FRAME_STATUS);
    CHECK(status && (status[4] | status[5] << 8) == CONFIG_ZMK_CLIPBOARD_OPAQUE_MAX_LEN);

    /* A computer with no helper gets its own paste, at once. */
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    advance(50);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    CHECK(host_len > 0);
    advance(3000);
    expect_host("opaque clip on a bare host", "<Cmd+v>");

    clear_host();
    select_endpoint(ZMK_TRANSPORT_USB, 0);
    chord(KEY_LCTRL, HID_USAGE_KEY_KEYBOARD_V);
    advance(3000);
    expect_host("opaque clip over USB", "<Ctrl+v>");

    /* Text that follows is text again. */
    clear_host();
    helper_copy(0, "plain");
    advance(10);
    CHECK(clip.valid && !clip.opaque && clip.typable);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(3000);
    expect_host("text after an opaque clip", "plain");
}

static void test_opaque_clip_goes_only_to_helpers_that_know_it(void) {
    reset();
    helper_hello(0);
    advance(10);
    helper_copy_opaque(0, (const uint8_t *)ticket, TICKET_LEN);
    helper_hello_v1(1);
    advance(10);

    /* An old helper would put the message on the clipboard as if it were
     * text. It is not offered, and the paste is not kept waiting for it. */
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    advance(300);
    CHECK(helper_frame(1, CLIP_FRAME_BEGIN) == NULL);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(100);
    expect_host("old helper, opaque clip", "<Cmd+v>");
    CHECK(helpers & BIT(1));

    /* The old helper still gets text. */
    clear_host();
    helper_copy(0, "words");
    advance(10);
    select_endpoint(ZMK_TRANSPORT_BLE, 0);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    advance(300);
    CHECK(helper_frame(1, CLIP_FRAME_BEGIN) != NULL);

    reset();
    uint32_t crc = ticket_delivered_to_profile_1();
    helper_ack(1, crc);
    advance(10);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(3000);
    expect_host("new helper, opaque clip", "<Cmd+v>");
}

static void test_hold_keeps_a_paste_back_until_fetched(void) {
    reset();
    uint32_t crc = ticket_delivered_to_profile_1();

    /* The helper is fetching over the network and says so. The paste, and
     * what is typed behind it, wait well past the usual allowance. */
    helper_hold(1, CLIP_HOLD_SOON);
    advance(50);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    key(HID_USAGE_KEY_KEYBOARD_X, true);
    advance(40);
    key(HID_USAGE_KEY_KEYBOARD_X, false);
    for (int i = 0; i < 4; i++) {
        advance(CLIP_HOLD_REPEAT_MS);
        helper_hold(1, CLIP_HOLD_SOON);
    }
    advance(10);
    CHECK(host_len == 0);
    CHECK(CLIP_HOLD_REPEAT_MS * 4 > CONFIG_ZMK_CLIPBOARD_ACK_WAIT_MS);

    helper_ack(1, crc);
    advance(200);
    expect_host("paste held for a fetch", "<Cmd+v>x");
    CHECK(!fetch.active);
}

static void test_hold_does_not_keep_a_paste_back_for_ever(void) {
    reset();
    ticket_delivered_to_profile_1();

    helper_hold(1, CLIP_HOLD_SOON);
    advance(50);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    key(HID_USAGE_KEY_KEYBOARD_X, true);
    advance(40);
    key(HID_USAGE_KEY_KEYBOARD_X, false);

    int64_t pressed = now;
    while (now - pressed < FETCH_WAIT_MAX_MS - CLIP_HOLD_REPEAT_MS) {
        advance(CLIP_HOLD_REPEAT_MS);
        helper_hold(1, CLIP_HOLD_SOON);
        CHECK(host_len == 0);
    }
    advance(CLIP_HOLD_REPEAT_MS);
    CHECK(now - pressed > FETCH_WAIT_MAX_MS);

    /* The paste is dropped, since letting it through would put down what the
     * clipboard held before. The keys behind it come out. The helper kept
     * repeating its HOLD the whole time, so it is still counted as a helper
     * and the next paste waits on it like the first. */
    expect_host("fetch that never finished", "x");
    CHECK(helpers & BIT(1));
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    CHECK(strcmp(host_out, "x") == 0 && pending_paste.active);
    helper_hold(1, 0);
    advance(20);
    expect_host("second paste, same fetch", "x");
}

static void test_long_fetch_drops_pastes(void) {
    reset();
    uint32_t crc = ticket_delivered_to_profile_1();

    /* A HOLD without SOON: the fetch will take too long to hold the keyboard
     * up for. */
    helper_hold(1, 0);
    advance(50);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    key(HID_USAGE_KEY_KEYBOARD_X, true);
    CHECK(strcmp(host_out, "x") == 0);
    advance(40);
    key(HID_USAGE_KEY_KEYBOARD_X, false);
    advance(100);
    expect_host("paste during a long fetch", "x");

    /* A paste that was already waiting when the helper said so goes too. */
    clear_host();
    helper_hold(1, CLIP_HOLD_SOON);
    advance(20);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    CHECK(pending_paste.active);
    helper_hold(1, 0);
    advance(20);
    expect_host("waiting paste, fetch turned long", "");

    helper_ack(1, crc);
    advance(10);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(100);
    expect_host("paste once it is fetched", "<Cmd+v>");
}

static void test_hold_lapses_and_can_be_ended(void) {
    reset();
    ticket_delivered_to_profile_1();

    /* A helper that stops saying it is fetching is no longer believed. */
    helper_hold(1, 0);
    advance(CLIP_HOLD_LAPSE_MS + 1);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(CONFIG_ZMK_CLIPBOARD_ACK_WAIT_MS + 200);
    expect_host("lapsed hold", "<Cmd+v>");

    reset();
    ticket_delivered_to_profile_1();
    helper_hold(1, 0);
    advance(20);
    helper_hold(1, CLIP_HOLD_OFF);
    advance(20);
    CHECK(!fetch.active);

    /* A helper that says HELLO has only just started, and is not the one
     * that was fetching. It may be an older one, too. */
    helper_hold(1, 0);
    advance(20);
    CHECK(fetch.active && (helpers_opaque & BIT(1)));
    helper_hello_v1(1);
    advance(20);
    CHECK(!fetch.active && (helpers & BIT(1)) && !(helpers_opaque & BIT(1)));

    /* The hold also ends when its helper disconnects. */
    helper_hello(1);
    advance(300);
    helper_hold(1, 0);
    advance(20);
    CHECK(fetch.active);
    conns[1].connected = false;
    on_disconnected(&conns[1], 0);
    advance(20);
    CHECK(!fetch.active);
}

static void test_hold_never_blocks_a_local_paste(void) {
    reset();
    ticket_delivered_to_profile_1();
    helper_hold(1, 0);
    advance(20);

    /* Something is copied on the computer that was fetching. The clip it was
     * fetching for is gone, and so is its claim on the paste key, even if it
     * has not caught up yet and asks again. */
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_C);
    advance(20);
    helper_hold(1, 0);
    advance(20);
    CHECK(!fetch.active);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(100);
    expect_host("copy and paste where a fetch was running", "<Cmd+c><Cmd+v>");

    /* Nor can the helper where the clip was copied hold up its own paste. */
    reset();
    ticket_delivered_to_profile_1();
    helper_hold(0, 0);
    select_endpoint(ZMK_TRANSPORT_BLE, 0);
    advance(20);
    CHECK(!fetch.active);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(100);
    expect_host("hold from the origin", "<Cmd+v>");
}

static void test_relay_passes_between_the_two_helpers(void) {
    reset();
    ticket_delivered_to_profile_1();
    inbox[0].count = 0;

    /* From the receiving end to where the clip was copied, and back. */
    helper_relay(1, "send it over");
    advance(10);
    CHECK(helper_got_relay(0, "send it over"));
    CHECK(!helper_got_relay(1, "send it over"));

    helper_relay(0, "cannot");
    advance(10);
    CHECK(helper_got_relay(1, "cannot"));

    /* A busy link delays it rather than losing it. */
    tx_credits_per_tick = 0;
    advance(1);
    helper_relay(1, "again");
    advance(40);
    CHECK(!helper_got_relay(0, "again"));
    tx_credits_per_tick = 3;
    advance(40);
    CHECK(helper_got_relay(0, "again"));

    /* Too long for the link it would leave on. */
    inbox[1].count = 0;
    helper_relay(1, "twenty bytes or more of it");
    advance(10);
    CHECK(!helper_got_relay(0, "twenty bytes or more of it"));
    CHECK(helper_got_unreachable(1));

    /* Longer than any relay may be: dropped where it arrives. */
    char oversize[CLIP_RELAY_MAX + 1];
    memset(oversize, 'a', sizeof(oversize) - 1);
    oversize[sizeof(oversize) - 1] = '\0';
    helper_relay(1, oversize);
    CHECK(!relay.owed);
    advance(10);

    /* An answer goes to whoever asked, wherever the keyboard has been
     * switched to since. */
    inbox[1].count = 0;
    select_endpoint(ZMK_TRANSPORT_BLE, 2);
    helper_hello(2);
    advance(300);
    helper_relay(0, "for the asker");
    advance(10);
    CHECK(helper_got_relay(1, "for the asker"));
    CHECK(!helper_got_relay(2, "for the asker"));

    /* That includes the clip that replaces the one asked after. */
    helper_copy_opaque(0, (const uint8_t *)ticket, TICKET_LEN);
    advance(300);
    inbox[1].count = 0;
    helper_relay(0, "still for the asker");
    advance(10);
    CHECK(helper_got_relay(1, "still for the asker"));

    /* With no clip there is no other end. */
    inbox[1].count = 0;
    const uint8_t clear[] = {CLIP_FRAME_CLEAR};
    helper_write(0, clear, sizeof(clear));
    advance(10);
    helper_relay(1, "too late");
    advance(10);
    CHECK(!helper_got_relay(0, "too late"));
    CHECK(helper_got_unreachable(1));

    /* Nobody has asked: word from where the clip was copied goes to the
     * selected computer, if it has a helper that would understand it. */
    reset();
    helper_hello(0);
    advance(10);
    helper_copy_opaque(0, (const uint8_t *)ticket, TICKET_LEN);
    select_endpoint(ZMK_TRANSPORT_BLE, 2);
    advance(10);
    inbox[0].count = 0;
    helper_relay(0, "anyone");
    advance(10);
    CHECK(helper_got_unreachable(0));

    inbox[0].count = 0;
    helper_hello_v1(2);
    advance(10);
    helper_relay(0, "anyone");
    advance(10);
    CHECK(!helper_got_relay(2, "anyone"));
    CHECK(helper_got_unreachable(0));

    inbox[0].count = 0;
    helper_hello(2);
    advance(300);
    helper_relay(0, "anyone");
    advance(10);
    CHECK(helper_got_relay(2, "anyone"));

    /* Word sent just ahead of a clip of the sender's own still goes to the
     * computer the old clip came from, though by the time it is passed on
     * the clip in hand says otherwise. */
    reset();
    ticket_delivered_to_profile_1();
    inbox[0].count = 0;
    helper_relay(1, "never mind");
    helper_copy(1, "copied here instead");
    advance(10);
    CHECK(helper_got_relay(0, "never mind"));
    CHECK(clip.valid && clip.origin == 1);

    /* A frame of the greatest length allowed, over a link that takes it. */
    reset();
    ticket_delivered_to_profile_1();
    conns[0].mtu = 100;
    char longest[CLIP_RELAY_MAX];
    memset(longest, 'b', sizeof(longest) - 1);
    longest[sizeof(longest) - 1] = '\0';
    helper_relay(1, longest);
    advance(10);
    CHECK(helper_got_relay(0, longest));
    check_idle("relay");
}

static void test_each_kind_has_its_own_limit(void) {
    static uint8_t big[CONFIG_ZMK_CLIPBOARD_OPAQUE_MAX_LEN + 1];
    static char got[CLIP_BUF_LEN + 1];
    uint32_t crc = 0;

    for (size_t i = 0; i < sizeof(big); i++) {
        big[i] = (uint8_t)(i * 7 + 1);
    }

    /* Messages between helpers may be longer than text is allowed to be, as
     * nobody wants that much typed. */
    reset();
    helper_hello(0);
    advance(10);
    helper_copy_bytes(0, big, CONFIG_ZMK_CLIPBOARD_MAX_LEN + 1, CLIP_FLAG_USB_KNOWN,
                      clip_crc32(big, CONFIG_ZMK_CLIPBOARD_MAX_LEN + 1));
    advance(10);
    CHECK(!clip.valid);
    const uint8_t *answer = helper_frame(0, CLIP_FRAME_RESULT);
    CHECK(answer && answer[1] == CLIP_RESULT_TOO_LONG);

    inbox[0].count = 0;
    helper_copy_opaque(0, big, CONFIG_ZMK_CLIPBOARD_OPAQUE_MAX_LEN + 1);
    advance(10);
    CHECK(!clip.valid);
    answer = helper_frame(0, CLIP_FRAME_RESULT);
    CHECK(answer && answer[1] == CLIP_RESULT_TOO_LONG);

    /* A clip that was refused is not one a helper can be fetching for. */
    helper_hello(1);
    helper_hold(1, 0);
    advance(10);
    CHECK(!fetch.active);

    /* The longest one allowed arrives whole. */
    inbox[0].count = 0;
    helper_copy_opaque(0, big, CONFIG_ZMK_CLIPBOARD_OPAQUE_MAX_LEN);
    advance(10);
    CHECK(clip.valid && clip.len == CONFIG_ZMK_CLIPBOARD_OPAQUE_MAX_LEN);
    helper_hello(1);
    advance(10);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    advance(2000);
    CHECK(helper_received(1, got, sizeof(got), &crc));
    CHECK(memcmp(got, big, CONFIG_ZMK_CLIPBOARD_OPAQUE_MAX_LEN) == 0);
    CHECK(crc == clip_crc32(big, CONFIG_ZMK_CLIPBOARD_OPAQUE_MAX_LEN));
    check_idle("limits");
}

static void test_paste_waits_while_the_clip_keeps_arriving(void) {
    const char *text = "a long one, sent a little at a time";
    uint16_t len = (uint16_t)strlen(text);
    uint8_t frame[20];
    uint16_t offset = 0;
    uint16_t taken;

    /* Copied on one computer and pasted on the next before the clip has
     * finished coming in, over a link that takes its time. */
    reset();
    helper_hello(0);
    advance(10);
    helper_write(0, frame,
                 clip_encode_begin(frame, CLIP_FLAG_USB_KNOWN, len,
                                   clip_crc32((const uint8_t *)text, len)));
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    advance(10);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);

    while (offset < len) {
        size_t n = clip_encode_data(frame, 8, (const uint8_t *)text, len, offset, &taken);

        advance(CONFIG_ZMK_CLIPBOARD_ACK_WAIT_MS - 250);
        CHECK(host_len == 0);
        helper_write(0, frame, n);
        offset = (uint16_t)(offset + taken);
    }
    frame[0] = CLIP_FRAME_END;
    helper_write(0, frame, 1);
    advance(3000);
    expect_host("clip that arrived slowly", text);

    /* One that stops coming is not waited for, however much else is going
     * on in the meantime. */
    reset();
    helper_hello(0);
    advance(10);
    helper_write(0, frame,
                 clip_encode_begin(frame, CLIP_FLAG_USB_KNOWN, len,
                                   clip_crc32((const uint8_t *)text, len)));
    helper_write(0, frame, clip_encode_data(frame, 8, (const uint8_t *)text, len, 0, &taken));
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    advance(10);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    for (int i = 0; i < 6; i++) {
        advance(200);
        helper_hello(2);
    }
    expect_host("clip that stopped arriving", "<Cmd+v>");
}

static void test_expiry_lets_a_delivery_finish(void) {
    static uint8_t big[CONFIG_ZMK_CLIPBOARD_OPAQUE_MAX_LEN];
    static char got[CLIP_BUF_LEN + 1];
    uint32_t crc = 0;

    memset(big, 'z', sizeof(big));

    reset();
    helper_hello(0);
    advance(10);
    helper_copy_opaque(0, big, sizeof(big));
    helper_hello(1);
    advance((int64_t)CONFIG_ZMK_CLIPBOARD_TTL_SEC * 1000 - 100);
    CHECK(clip.valid);

    /* Switched to with a moment left, over a link slow enough that the
     * handover runs past it. */
    tx_credits_per_tick = 1;
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    advance(200);
    CHECK(clip.valid && delivery.active && delivery.phase != DELIVER_AWAIT_ACK);
    advance(2000);
    CHECK(helper_received(1, got, sizeof(got), &crc));
    CHECK(crc == clip_crc32(big, sizeof(big)));

    /* Once it has been handed over, it expires. */
    advance(1100);
    CHECK(!clip.valid);
    check_idle("expiry during delivery");
}

/* Taps a key the way typing does. */
static void tap(uint32_t usage) {
    key(usage, true);
    advance(40);
    key(usage, false);
    advance(40);
}

static void test_many_keys_behind_a_waiting_paste_stay_in_order(void) {
    char want[64] = {0};

    reset();
    ticket_delivered_to_profile_1();
    helper_hold(1, CLIP_HOLD_SOON);
    advance(20);

    /* More typing behind the paste than there is room to queue. The paste is
     * dropped, and every key comes out once, in order, as itself rather than
     * as a shortcut, with none left down. */
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    for (int i = 0; i < 40; i++) {
        uint32_t usage = 0x04 + (uint32_t)(i % 26);

        if (i % 5 == 0) {
            helper_hold(1, CLIP_HOLD_SOON);
        }
        key(usage, true);
        advance(15);
        key(usage, false);
        advance(15);
        want[i] = (char)('a' + i % 26);
    }
    CHECK(40 * 2 > HELD_MAX);
    advance(200);
    expect_host("more keys than the queue holds", want);
}

static void test_key_let_go_after_typing_starts_is_not_left_down(void) {
    const char *text = "typed after all";
    char want[32];

    /* Enter goes down while the paste is still waiting on a helper that will
     * never answer, and comes up once the clip is being typed instead. */
    reset();
    copy_on_profile_0(text);
    helper_hello(1);
    advance(10);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    advance(300);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(CONFIG_ZMK_CLIPBOARD_ACK_WAIT_MS - 40 - 115);
    CHECK(pending_paste.active);
    matrix_key(KEY_ENTER, true, true);
    advance(100);
    CHECK(job.kind == JOB_TYPE);
    /* A release does not stop the typing; only a press does. */
    struct zmk_keycode_state_changed_event up = {
        .header = {.event = &zmk_event_zmk_keycode_state_changed},
        .data = {.usage_page = HID_USAGE_KEY, .keycode = KEY_ENTER, .state = false},
    };
    if (clipboard_listener(&up.header) == ZMK_EV_EVENT_BUBBLE) {
        hid_listener(&up.data);
    }
    advance(3000);
    snprintf(want, sizeof(want), "%s\n", text);
    expect_host("key released during typing", want);

    /* The same with Shift, behind a clip that was still arriving. */
    reset();
    helper_hello(0);
    advance(10);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_C);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    advance(10);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    CHECK(pending_paste.active);
    key(0xE1, true);
    advance(20);
    helper_copy(0, "ab");
    advance(30);
    CHECK(job.kind == JOB_TYPE);
    struct zmk_keycode_state_changed_event shift_up = {
        .header = {.event = &zmk_event_zmk_keycode_state_changed},
        .data = {.usage_page = HID_USAGE_KEY, .keycode = 0xE1, .state = false},
    };
    if (clipboard_listener(&shift_up.header) == ZMK_EV_EVENT_BUBBLE) {
        hid_listener(&shift_up.data);
    }
    advance(3000);
    expect_host("modifier released during typing", "<Cmd+c>ab");
}

static void test_paste_pressed_twice_is_one_paste(void) {
    reset();
    uint32_t crc = ticket_delivered_to_profile_1();

    /* Pressed again out of impatience while the first is held: still one
     * paste when the fetch finishes. */
    helper_hold(1, CLIP_HOLD_SOON);
    advance(20);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(300);
    helper_hold(1, CLIP_HOLD_SOON);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(100);
    CHECK(host_len == 0);
    helper_ack(1, crc);
    advance(200);
    expect_host("two presses, fetched", "<Cmd+v>");

    /* And none when the first is dropped. Queued, the second would go out
     * as a paste of whatever the clipboard held before. */
    reset();
    ticket_delivered_to_profile_1();
    helper_hold(1, CLIP_HOLD_SOON);
    advance(20);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(300);
    helper_hold(1, CLIP_HOLD_SOON);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    tap(HID_USAGE_KEY_KEYBOARD_X);
    helper_hold(1, 0);
    advance(200);
    expect_host("two presses, dropped", "x");

    /* A plain v typed behind a waiting paste is a letter, not a paste. */
    reset();
    crc = ticket_delivered_to_profile_1();
    helper_hold(1, CLIP_HOLD_SOON);
    advance(20);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    tap(HID_USAGE_KEY_KEYBOARD_V);
    helper_ack(1, crc);
    advance(200);
    expect_host("letter v behind a paste", "<Cmd+v>v");
}

static void test_hold_outlasts_a_late_repeat(void) {
    reset();
    uint32_t crc = ticket_delivered_to_profile_1();

    /* The helper's repeats arrive when the link gets round to them. One that
     * is late, but inside the time a hold lasts, costs nothing. */
    helper_hold(1, CLIP_HOLD_SOON);
    advance(20);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(CONFIG_ZMK_CLIPBOARD_ACK_WAIT_MS + 150);
    CHECK(host_len == 0 && pending_paste.active);
    helper_hold(1, CLIP_HOLD_SOON);
    advance(400);
    helper_ack(1, crc);
    advance(200);
    expect_host("late repeat", "<Cmd+v>");

    /* A single one is enough to wait a second on. */
    reset();
    crc = ticket_delivered_to_profile_1();
    helper_hold(1, CLIP_HOLD_SOON);
    advance(20);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(1000);
    CHECK(host_len == 0);
    helper_ack(1, crc);
    advance(200);
    expect_host("one hold, answered within its span", "<Cmd+v>");

    /* A helper that says it is fetching and is never heard from again has
     * its paste let through when the hold lapses. */
    reset();
    ticket_delivered_to_profile_1();
    helper_hold(1, CLIP_HOLD_SOON);
    advance(20);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(CLIP_HOLD_LAPSE_MS - 200);
    CHECK(host_len == 0);
    advance(400);
    expect_host("hold that lapsed with a paste waiting", "<Cmd+v>");
}

static void test_helper_that_answers_late_is_believed_again(void) {
    reset();
    uint32_t crc = ticket_delivered_to_profile_1();

    /* Too slow to say anything before the paste gave up on it. */
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(CONFIG_ZMK_CLIPBOARD_ACK_WAIT_MS + 100);
    expect_host("helper silent at first", "<Cmd+v>");
    CHECK(!(helpers & BIT(1)));

    /* Then it turns out to be fetching after all. */
    clear_host();
    helper_hold(1, 0);
    advance(20);
    CHECK(helpers & BIT(1));
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(200);
    expect_host("paste while it fetches", "");

    helper_ack(1, crc);
    advance(20);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(200);
    expect_host("paste once it has", "<Cmd+v>");
}

static void test_expiry_waits_for_a_fetch(void) {
    reset();
    helper_hello(0);
    advance(10);
    helper_copy_opaque(0, (const uint8_t *)ticket, TICKET_LEN);
    helper_hello(1);
    advance((int64_t)CONFIG_ZMK_CLIPBOARD_TTL_SEC * 1000 - 2000);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    advance(300);
    inbox[0].count = 0;
    inbox[1].count = 0;

    /* The clip's time runs out while the helper is still fetching what it
     * refers to. It is kept, and word still passes between the helpers. */
    for (int i = 0; i < 12; i++) {
        helper_hold(1, 0);
        advance(CLIP_HOLD_REPEAT_MS);
    }
    CHECK(clip.valid && fetch.active);
    helper_relay(1, "send it over");
    advance(10);
    CHECK(helper_got_relay(0, "send it over"));
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    advance(100);
    expect_host("paste during a fetch past the clip's time", "");

    /* It is not kept for ever: once the helper stops saying it is fetching,
     * the clip goes. */
    advance(CLIP_HOLD_LAPSE_MS + 1100);
    CHECK(!clip.valid);

    /* Nor is it kept for a helper that never stops. */
    reset();
    helper_hello(0);
    advance(10);
    helper_copy_opaque(0, (const uint8_t *)ticket, TICKET_LEN);
    helper_hello(1);
    advance(10);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    advance(300);
    int64_t limit = (int64_t)CONFIG_ZMK_CLIPBOARD_TTL_SEC * 1000 + EXPIRY_GRACE_MS + 2000;
    for (int64_t t = 0; t < limit; t += CLIP_HOLD_REPEAT_MS) {
        helper_hold(1, 0);
        advance(CLIP_HOLD_REPEAT_MS);
    }
    CHECK(!clip.valid);
    check_idle("expiry during a fetch");
}

static void test_expiry_does_not_wait_on_a_stuck_delivery(void) {
    static uint8_t big[CONFIG_ZMK_CLIPBOARD_OPAQUE_MAX_LEN];

    memset(big, 'q', sizeof(big));
    reset();
    helper_hello(0);
    advance(10);
    helper_copy_opaque(0, big, sizeof(big));
    helper_hello(1);
    advance(10);

    /* The link to the helper stops taking anything and never recovers. */
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    advance(5);
    tx_credits_per_tick = 0;
    advance((int64_t)CONFIG_ZMK_CLIPBOARD_TTL_SEC * 1000 + 1000);
    CHECK(clip.valid);
    advance(EXPIRY_GRACE_MS + 1000);
    CHECK(!clip.valid);
    check_idle("stuck delivery");
}

static void test_stale_hold_does_not_claim_a_newer_text_clip(void) {
    char got[CLIP_BUF_LEN + 1];
    uint32_t crc = 0;

    reset();
    ticket_delivered_to_profile_1();
    helper_hold(1, 0);
    advance(20);

    /* Back to the first computer, where text is copied; then to the second,
     * whose helper has not yet heard of it and is still asking for pastes to
     * be dropped on account of the old clip. */
    select_endpoint(ZMK_TRANSPORT_BLE, 0);
    helper_hold(1, 0);
    advance(100);
    helper_copy(0, "newer words");
    advance(10);
    helper_hold(1, 0);
    advance(10);
    CHECK(!fetch.active);

    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    helper_hold(1, 0);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    CHECK(pending_paste.active);
    advance(200);
    CHECK(helper_received(1, got, sizeof(got), &crc));
    CHECK(strcmp(got, "newer words") == 0);
    helper_ack(1, crc);
    advance(100);
    expect_host("text copied since the fetch began", "<Cmd+v>");

    /* The same with another image copied instead. The stale request does
     * take hold of that clip while it sits in the keyboard, but not past the
     * moment it is handed to the helper that made it. */
    reset();
    ticket_delivered_to_profile_1();
    helper_hold(1, 0);
    select_endpoint(ZMK_TRANSPORT_BLE, 0);
    advance(100);
    helper_copy_opaque(0, (const uint8_t *)"a newer ticket", 14);
    advance(10);
    helper_hold(1, 0);
    advance(10);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    CHECK(host_len == 0 && pending_paste.active);
    advance(100);
    CHECK(helper_received(1, got, sizeof(got), &crc));
    helper_hold(1, CLIP_HOLD_SOON);
    advance(200);
    CHECK(pending_paste.active);
    helper_ack(1, crc);
    advance(100);
    expect_host("image copied since the fetch began", "<Cmd+v>");
}

static void test_opaque_clip_still_arriving_holds_nothing_up_on_a_bare_host(void) {
    uint8_t frame[20];

    reset();
    helper_hello(0);
    advance(10);
    helper_write(0, frame,
                 clip_encode_begin(frame, CLIP_FLAG_USB_KNOWN | CLIP_FLAG_OPAQUE, 500, 0x1234));
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    advance(10);

    /* Whatever it turns out to be, it is not for this computer. */
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    CHECK(host_len > 0);
    advance(100);
    expect_host("opaque clip arriving, bare host", "<Cmd+v>");

    /* With a helper that could use it, the paste does wait. */
    clear_host();
    helper_hello(2);
    select_endpoint(ZMK_TRANSPORT_BLE, 2);
    advance(10);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    CHECK(host_len == 0 && pending_paste.active);
    advance(CONFIG_ZMK_CLIPBOARD_ACK_WAIT_MS + 100);
    expect_host("opaque clip that stopped arriving", "<Cmd+v>");
}

static void test_paste_waits_out_a_slow_delivery(void) {
    static uint8_t big[CONFIG_ZMK_CLIPBOARD_OPAQUE_MAX_LEN];
    static char got[CLIP_BUF_LEN + 1];
    uint32_t crc = 0;

    memset(big, 'k', sizeof(big));
    reset();
    helper_hello(0);
    advance(10);
    helper_copy_opaque(0, big, sizeof(big));
    helper_hello(1);
    advance(10);
    tx_credits_per_tick = 0;
    advance(1);
    select_endpoint(ZMK_TRANSPORT_BLE, 1);
    chord(KEY_LGUI, HID_USAGE_KEY_KEYBOARD_V);
    CHECK(delivery.active && pending_paste.active);

    /* A link that takes a few frames, then nothing for a while, for longer
     * altogether than a paste waits on a helper that has gone quiet. */
    int64_t started = now;
    while (delivery.active && delivery.phase != DELIVER_AWAIT_ACK) {
        tx_credits_per_tick = 1;
        advance(24);
        tx_credits_per_tick = 0;
        advance(200);
        CHECK(host_len == 0);
        CHECK(now - started < 60000);
    }
    CHECK(now - started > 2 * CONFIG_ZMK_CLIPBOARD_ACK_WAIT_MS);
    tx_credits_per_tick = 3;
    CHECK(helper_received(1, got, sizeof(got), &crc));
    helper_ack(1, crc);
    advance(200);
    expect_host("paste behind a slow delivery", "<Cmd+v>");
}

int main(void) {
#ifdef CLIP_TEST_SMALL_OPAQUE
    /* Built with the opaque limit below the text limit. The buffer then has
     * room past the opaque limit, so only the limit check can stop a clip. */
    static uint8_t bytes[CONFIG_ZMK_CLIPBOARD_MAX_LEN];

    memset(bytes, 'm', sizeof(bytes));
    _Static_assert(CONFIG_ZMK_CLIPBOARD_OPAQUE_MAX_LEN < CONFIG_ZMK_CLIPBOARD_MAX_LEN, "");
    reset();
    helper_hello(0);
    advance(10);
    helper_copy_opaque(0, bytes, CONFIG_ZMK_CLIPBOARD_OPAQUE_MAX_LEN + 1);
    advance(10);
    CHECK(!clip.valid);
    const uint8_t *refusal = helper_frame(0, CLIP_FRAME_RESULT);
    CHECK(refusal && refusal[1] == CLIP_RESULT_TOO_LONG);
    helper_copy_opaque(0, bytes, CONFIG_ZMK_CLIPBOARD_OPAQUE_MAX_LEN);
    advance(10);
    CHECK(clip.valid && clip.opaque);
    helper_copy_bytes(0, bytes, CONFIG_ZMK_CLIPBOARD_MAX_LEN, CLIP_FLAG_USB_KNOWN,
                      clip_crc32(bytes, CONFIG_ZMK_CLIPBOARD_MAX_LEN));
    advance(10);
    CHECK(clip.valid && !clip.opaque && clip.len == CONFIG_ZMK_CLIPBOARD_MAX_LEN);
    check_idle("small opaque limit");

    if (failures) {
        printf("%d failure(s)\n", failures);
        return 1;
    }
    printf("clipboard sim, small opaque limit: ok\n");
    return 0;
#endif

    test_types_on_a_bare_host();
    test_held_modifier_never_leaks();
    test_paste_on_the_origin_is_left_alone();
    test_delivers_to_a_helper();
    test_paste_waits_for_the_helper();
    test_silent_helper_falls_back_to_typing();
    test_expiry_wipes_the_clip();
    test_copy_elsewhere_makes_the_clip_stale();
    test_any_key_stops_the_typing();
    test_new_clip_replaces_one_being_typed();
    test_switching_away_stops_the_typing();
    test_usb();
    test_helper_disconnects();
    test_delivery_survives_a_busy_link();
    test_bad_clips_are_refused();
    test_only_profiles_may_write();
    test_other_shortcuts_pass();
    test_typographic_text();
    test_typing_takes_a_report_per_character();
    test_typing_lets_go_where_it_has_to();
    test_without_intercept();
    test_keys_behind_a_waiting_paste_keep_their_place();
    test_fast_switch_waits_for_the_new_clip();
    test_layer_key_stops_a_job_before_a_switch();
    test_expiry_lets_typing_finish();
    test_late_expiry_spares_a_newer_clip();
    test_untypable_clip_is_not_swallowed();
    test_replies_survive_a_full_link();
    test_slow_link_paces_the_typing();
    test_forgets_a_profile_that_went_away();
    test_opaque_clip_is_never_typed();
    test_opaque_clip_goes_only_to_helpers_that_know_it();
    test_hold_keeps_a_paste_back_until_fetched();
    test_hold_does_not_keep_a_paste_back_for_ever();
    test_long_fetch_drops_pastes();
    test_hold_lapses_and_can_be_ended();
    test_hold_never_blocks_a_local_paste();
    test_relay_passes_between_the_two_helpers();
    test_each_kind_has_its_own_limit();
    test_paste_waits_while_the_clip_keeps_arriving();
    test_expiry_lets_a_delivery_finish();
    test_many_keys_behind_a_waiting_paste_stay_in_order();
    test_key_let_go_after_typing_starts_is_not_left_down();
    test_paste_pressed_twice_is_one_paste();
    test_hold_outlasts_a_late_repeat();
    test_helper_that_answers_late_is_believed_again();
    test_expiry_waits_for_a_fetch();
    test_expiry_does_not_wait_on_a_stuck_delivery();
    test_stale_hold_does_not_claim_a_newer_text_clip();
    test_opaque_clip_still_arriving_holds_nothing_up_on_a_bare_host();
    test_paste_waits_out_a_slow_delivery();

    if (failures) {
        printf("%d failure(s)\n", failures);
        return 1;
    }

    printf("clipboard sim: ok\n");
    return 0;
}
