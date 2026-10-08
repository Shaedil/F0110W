/*
 * Copyright (c) 2026 M0110 ZMK Driver
 * SPDX-License-Identifier: MIT
 *
 * Clipboard courier: carries copied text from one paired computer to another.
 *
 * A keyboard cannot read a computer's clipboard, so the computer that is
 * copied from runs a helper, which writes each new clip to the GATT service
 * below. The keyboard holds the clip in RAM and remembers which Bluetooth
 * profile it came from. After a switch to a different computer, how the clip
 * gets across depends on whether that computer runs a helper too:
 *
 *   - If it does, the clip is notified to it as soon as the switch lands, the
 *     helper puts it on the clipboard and acknowledges, and paste is left
 *     alone: it is a native paste of the right text.
 *   - If it does not, paste (V with Cmd or Ctrl) is swallowed and the clip is
 *     typed out as keystrokes instead.
 *
 * So the receiving side needs nothing installed, and gets better fidelity if
 * it has the helper anyway.
 *
 * What does not fit through a keyboard, an image or a long text, travels as
 * an opaque clip instead: a short message from one helper to the other saying
 * where to fetch the real thing. The keyboard carries it like any clip, hands
 * it only to a helper, and never types it. While the helper on the receiving
 * computer is fetching, it asks for pastes there to be held back (HOLD), and
 * it can send word to the helper it came from (RELAY).
 *
 * ## Threads
 *
 * GATT writes arrive on a Bluetooth thread; key events, the keystroke job and
 * delivery run on the system work queue. The Bluetooth side only records what
 * arrived and submits `evaluate_work`; every call into ZMK's HID and endpoint
 * code, none of which is thread-safe, happens on the work queue.
 *
 * `lock` guards the state both sides touch, and is never held across a HID
 * report or a notification. Either can wait on the link, and the Bluetooth
 * thread that would get the link moving must not be stuck behind this mutex.
 *
 * ## Retention
 *
 * The keyboard keeps one clip, in RAM and never in settings. It is zeroed
 * when it expires, when a newer copy is seen anywhere, and at reset. The
 * service needs an encrypted link, and ZMK only encrypts to bonded hosts, so
 * a computer that was never paired can neither read nor write it.
 */

#include <string.h>

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/init.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/util.h>

#include <dt-bindings/zmk/hid_usage.h>
#include <dt-bindings/zmk/hid_usage_pages.h>
#include <dt-bindings/zmk/modifiers.h>
#include <zmk/ble.h>
#include <zmk/endpoints.h>
#include <zmk/event_manager.h>
#include <zmk/events/endpoint_changed.h>
#include <zmk/events/keycode_state_changed.h>
#include <zmk/events/position_state_changed.h>
#include <zmk/hid.h>

#include "clip_proto.h"
#include "clip_text.h"

LOG_MODULE_REGISTER(zmk_clipboard, CONFIG_ZMK_LOG_LEVEL);

BUILD_ASSERT(ZMK_BLE_PROFILE_COUNT <= 8, "per-profile state is kept in 8-bit masks");

#define CLIP_UUID(num) BT_UUID_128_ENCODE(num, 0xeec8, 0x443b, 0x9ede, 0x2919a6354188)
#define CLIP_SERVICE_UUID BT_UUID_DECLARE_128(CLIP_UUID(0xb02961de))
#define CLIP_RX_UUID BT_UUID_DECLARE_128(CLIP_UUID(0xb02961df))
#define CLIP_TX_UUID BT_UUID_DECLARE_128(CLIP_UUID(0xb02961e0))

/* The largest frame built for a notification. Bounded so the frame can live
 * on the work queue's stack; the link's MTU usually bounds it far lower. */
#define TX_FRAME_MAX 128
/* Frames sent per pass of the delivery job, so a long clip shares the link's
 * transmit buffers with HID reports instead of starving them. */
#define TX_FRAMES_PER_PASS 4
#define TX_RETRY K_MSEC(8)

/* How long after a copy shortcut the helper on that computer is given to say
 * what was copied, before a paste elsewhere stops waiting for it. Covers the
 * helper noticing, plus the transfer of an ordinary clip. */
#define COPY_WAIT K_MSEC(1200)

/* Key events held back behind a paste that has not gone out yet: room for a
 * few seconds of fast typing, which is as long as a paste is ever kept back. */
#define HELD_MAX 64

/* The longest a paste is kept back for a helper that says it is fetching. A
 * transfer that is making progress is waited out however long it takes, since
 * its size bounds it; a fetch has no such bound. */
#define FETCH_WAIT_MAX_MS 3000

/* How far past its time a clip is kept because it is still being handed over. */
#define EXPIRY_GRACE_MS 60000

/* One buffer serves both kinds of clip; each kind has its own limit. */
#define CLIP_BUF_LEN MAX(CONFIG_ZMK_CLIPBOARD_MAX_LEN, CONFIG_ZMK_CLIPBOARD_OPAQUE_MAX_LEN)
BUILD_ASSERT(CLIP_BUF_LEN <= UINT16_MAX, "clip lengths and offsets are 16 bits on the wire");

#define MODS_COMMAND (MOD_LGUI | MOD_RGUI | MOD_LCTL | MOD_RCTL)
#define MODS_ALT (MOD_LALT | MOD_RALT)
#define MODS_ALL 0xFF

static K_MUTEX_DEFINE(lock);

/* ---- Shared with the Bluetooth thread; guarded by `lock` ---- */

/* The clip. `generation` changes whenever its content does, so a job that
 * started on one clip notices it has been replaced. */
static struct {
    uint8_t buf[CLIP_BUF_LEN];
    struct clip_rx rx;
    bool valid;
    /* A message between helpers rather than text; see CLIP_FLAG_OPAQUE. */
    bool opaque;
    /* At least one character of it can be typed. A clip with none is still
     * worth delivering to a helper, but there is nothing to type. */
    bool typable;
    uint16_t len;
    uint32_t crc;
    uint16_t generation;
    /* Uptime at which it is wiped. */
    int64_t expires_at;
    /* Bluetooth profile the clip was copied on. */
    uint8_t origin;
    /* Whether the keyboard's USB port leads to that same computer; see
     * CLIP_FLAG_USB_KNOWN. */
    bool usb_known;
    bool usb_local;
    /* Profiles whose helper has confirmed the clip is on its clipboard. */
    uint8_t delivered;
    /* The profile whose helper last sent word to the one the clip came from,
     * which is where an answer goes; -1 if none has. */
    int8_t requester;
} clip;

/* A copy shortcut went to a computer with a helper, and the helper has not
 * yet said what, if anything, it put on the clipboard. */
static struct {
    bool active;
    uint8_t profile;
} expected;

/* Profiles with a helper listening on the current connection. */
static uint8_t helpers;
/* Those of them that know what to do with an opaque clip. */
static uint8_t helpers_opaque;
/* Notifications owed to helpers, sent from the work queue. */
static uint8_t status_owed;
static uint8_t poke_owed;
static struct {
    bool owed;
    uint8_t profile;
    enum clip_result code;
    uint32_t crc;
} result;

/* A datagram from one helper on its way to another. Only the latest is kept:
 * the helpers time out and ask again, so there is nothing to queue for. */
static struct {
    bool owed;
    uint8_t from;
    /* Where it is going, if that was settled when it arrived; -1 if not. */
    int8_t to;
    uint8_t len;
    uint8_t frame[CLIP_RELAY_MAX];
} relay;

/* The helper on a profile is fetching what the clip refers to, and has asked
 * for pastes on its computer to be kept back until it has. */
static struct {
    bool active;
    uint8_t profile;
    /* Worth holding a paste for; otherwise the paste is dropped. */
    bool soon;
    /* Uptime at which the request lapses unless repeated. */
    int64_t until;
} fetch;

/* Notifying the clip to the helper on the active profile. */
static struct {
    bool active;
    uint8_t profile;
    uint16_t generation;
    enum { DELIVER_BEGIN, DELIVER_DATA, DELIVER_END, DELIVER_AWAIT_ACK } phase;
    uint16_t offset;
} delivery;

/* ---- Work queue only ---- */

/* A paste that was swallowed while it is not yet known what should come out:
 * the clip may still be arriving from where it was copied, or the helper here
 * may be about to acknowledge it. It ends as a native paste or as typing. */
static struct {
    bool active;
    bool timed_out;
    uint8_t mods;
    /* Uptime past which a fetching helper is not waited on any longer. */
    int64_t give_up_at;
} pending_paste;

/* How much of the incoming transfer had arrived when `evaluate` last looked,
 * which is how it tells a transfer that is moving from one that has stalled. */
static uint16_t rx_seen;

/* Emitting keystrokes: either typing the clip out or replaying a paste. */
static struct {
    enum { JOB_NONE, JOB_TYPE, JOB_PASTE } kind;
    uint16_t generation;
    size_t pos;
    struct clip_key keys[CLIP_TEXT_MAX_KEYS];
    uint8_t key_count;
    uint8_t key_index;
    bool key_down;
    uint8_t usage;
    /* The implicit modifiers that went down with `usage`. */
    uint8_t usage_mods;
    uint8_t mods;
    k_timeout_t interval;
} job;

/* Keys whose press was swallowed, so the matching release is swallowed too
 * rather than reaching the host as a release of a key it never saw go down. */
static uint8_t swallowed[4];

/* The key press that stopped a typing job, identified by its timestamp, which
 * ZMK carries from the position event through to the keycode it produces. */
static struct {
    bool armed;
    int64_t timestamp;
} stopper;

/* Key events that arrived behind a paste still waiting to go out. They are
 * raised again, in order, once it has, so that Cmd-V Enter cannot turn into
 * Enter Cmd-V. */
static struct zmk_keycode_state_changed_event held[HELD_MAX];
static uint8_t held_count;

/* False if this listener turned out to run after ZMK's HID listener, where a
 * paste has already reached the host by the time it is seen. */
static bool intercept_ok;

static int clipboard_listener(const zmk_event_t *eh);
static void evaluate(struct k_work *work);
static void expire(struct k_work *work);
static void deliver(struct k_work *work);
static void job_step(struct k_work *work);
static void paste_timed_out(struct k_work *work);
static void copy_wait_over(struct k_work *work);

static K_WORK_DEFINE(evaluate_work, evaluate);
static K_WORK_DELAYABLE_DEFINE(evaluate_retry_work, evaluate);
static K_WORK_DELAYABLE_DEFINE(expire_work, expire);
static K_WORK_DELAYABLE_DEFINE(deliver_work, deliver);
static K_WORK_DELAYABLE_DEFINE(job_work, job_step);
static K_WORK_DELAYABLE_DEFINE(paste_timeout_work, paste_timed_out);
static K_WORK_DELAYABLE_DEFINE(copy_wait_work, copy_wait_over);

ZMK_LISTENER(clipboard, clipboard_listener);
ZMK_SUBSCRIPTION(clipboard, zmk_position_state_changed);
ZMK_SUBSCRIPTION(clipboard, zmk_keycode_state_changed);
ZMK_SUBSCRIPTION(clipboard, zmk_endpoint_changed);

/* Caller holds `lock`. */
static void clip_wipe(void) {
    memset(clip.buf, 0, sizeof(clip.buf));
    clip_rx_init(&clip.rx, clip.buf, sizeof(clip.buf));
    clip.valid = false;
    clip.opaque = false;
    clip.typable = false;
    clip.len = 0;
    clip.crc = 0;
    clip.delivered = 0;
    clip.generation++;
    clip.requester = -1;
    /* Whatever a helper was fetching went with it. One that is still at it,
     * because the clip was only replaced, says so again within a moment. */
    fetch.active = false;
}

/* Caller holds `lock`. */
static void clip_restart_expiry(void) {
    clip.expires_at = k_uptime_get() + (int64_t)CONFIG_ZMK_CLIPBOARD_TTL_SEC * 1000;
    k_work_reschedule(&expire_work, K_SECONDS(CONFIG_ZMK_CLIPBOARD_TTL_SEC));
}

/* Whether `endpoint` leads to a different computer than the clip came from.
 * Caller holds `lock`. */
static bool is_foreign(struct zmk_endpoint_instance endpoint) {
    switch (endpoint.transport) {
    case ZMK_TRANSPORT_BLE:
        return endpoint.ble.profile_index != clip.origin;
    case ZMK_TRANSPORT_USB:
        return clip.usb_known && !clip.usb_local;
    default:
        return false;
    }
}

/* Whether a clip is on its way from a computer other than the one `endpoint`
 * leads to: a transfer is in progress, or a copy shortcut was pressed there
 * and its helper has yet to report. Caller holds `lock`. */
static bool awaiting_clip(struct zmk_endpoint_instance endpoint) {
    if (clip.rx.active) {
        /* An opaque clip is no use to a computer with no helper for it, and
         * there is nothing to wait for. */
        if (clip.opaque && !(endpoint.transport == ZMK_TRANSPORT_BLE &&
                             (helpers_opaque & BIT(endpoint.ble.profile_index)))) {
            return false;
        }
        return is_foreign(endpoint);
    }

    return expected.active && endpoint.transport == ZMK_TRANSPORT_BLE &&
           endpoint.ble.profile_index != expected.profile;
}

/* Whether the helper on `endpoint` has asked for pastes to be kept back.
 * Caller holds `lock`. */
static bool fetching(struct zmk_endpoint_instance endpoint) {
    return fetch.active && endpoint.transport == ZMK_TRANSPORT_BLE &&
           endpoint.ble.profile_index == fetch.profile && k_uptime_get() < fetch.until;
}

/* The profile whose helper will report a copy made on `endpoint`, or -1 if
 * nothing will. Caller holds `lock`. */
static int copy_reporter(struct zmk_endpoint_instance endpoint) {
    switch (endpoint.transport) {
    case ZMK_TRANSPORT_BLE:
        return (helpers & BIT(endpoint.ble.profile_index)) ? endpoint.ble.profile_index : -1;
    case ZMK_TRANSPORT_USB:
        /* Only known to be a profile's computer through a clip that said so. */
        return ((clip.valid || clip.rx.active) && clip.usb_known && clip.usb_local &&
                (helpers & BIT(clip.origin)))
                   ? clip.origin
                   : -1;
    default:
        return -1;
    }
}

/* ---- GATT service ---- */

static ssize_t rx_write(struct bt_conn *conn, const struct bt_gatt_attr *attr, const void *buf,
                        uint16_t len, uint16_t offset, uint8_t flags);
static void tx_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value);

/* Static services are laid out in name order and their handles follow from
 * that. This name sorts after every service ZMK defines, so adding it leaves
 * the handles of the HID service, which paired hosts have cached, unchanged.
 *
 * The notify characteristic cannot be read, but carries the read-encrypt
 * permission anyway: it is what the stack checks before notifying, so a clip
 * can never go out over a link that is not encrypted. */
BT_GATT_SERVICE_DEFINE(zmk_clipboard_svc, BT_GATT_PRIMARY_SERVICE(CLIP_SERVICE_UUID),
                       BT_GATT_CHARACTERISTIC(CLIP_RX_UUID,
                                              BT_GATT_CHRC_WRITE | BT_GATT_CHRC_WRITE_WITHOUT_RESP,
                                              BT_GATT_PERM_WRITE_ENCRYPT, NULL, rx_write, NULL),
                       BT_GATT_CHARACTERISTIC(CLIP_TX_UUID, BT_GATT_CHRC_NOTIFY,
                                              BT_GATT_PERM_READ_ENCRYPT, NULL, NULL, NULL),
                       BT_GATT_CCC(tx_ccc_changed,
                                   BT_GATT_PERM_READ_ENCRYPT | BT_GATT_PERM_WRITE_ENCRYPT));

#define TX_ATTR (&zmk_clipboard_svc.attrs[4])

static void tx_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value) {
    ARG_UNUSED(attr);
    LOG_DBG("notifications %s", value == BT_GATT_CCC_NOTIFY ? "on" : "off");
}

/* The helper on `profile` has said what its latest copy was, one way or the
 * other. Caller holds `lock`. */
static void copy_reported(uint8_t profile) {
    if (expected.active && expected.profile == profile) {
        expected.active = false;
    }
}

static bool clip_has_keys(void) {
    struct clip_key keys[CLIP_TEXT_MAX_KEYS];
    size_t pos = 0;

    while (pos < clip.len) {
        if (clip_text_next(clip.buf, clip.len, &pos, keys) > 0) {
            return true;
        }
    }
    return false;
}

static void rx_begin(uint8_t profile, const uint8_t *frame, uint16_t len) {
    struct clip_begin begin;

    if (!clip_parse_begin(frame, len, &begin)) {
        return;
    }

    /* A copy just happened on that computer, so whatever was held is stale
     * whether or not the new clip turns out to be usable. */
    /* A clip that replaces one from the same computer may be its answer to
     * whoever asked after the last. */
    int8_t requester = profile == clip.origin ? clip.requester : -1;

    clip_wipe();
    clip.origin = profile;
    clip.requester = requester;
    clip.opaque = begin.flags & CLIP_FLAG_OPAQUE;
    clip.usb_known = begin.flags & CLIP_FLAG_USB_KNOWN;
    clip.usb_local = begin.flags & CLIP_FLAG_USB_LOCAL;

    if (begin.len == 0) {
        copy_reported(profile);
        return;
    }

    /* Restarted here as well as at END, so a transfer that never finishes
     * still gets zeroed. */
    clip_restart_expiry();

    size_t limit =
        clip.opaque ? CONFIG_ZMK_CLIPBOARD_OPAQUE_MAX_LEN : CONFIG_ZMK_CLIPBOARD_MAX_LEN;

    if (begin.len > limit || clip_rx_begin(&clip.rx, &begin) != CLIP_RESULT_OK) {
        result.owed = true;
        result.profile = profile;
        result.code = CLIP_RESULT_TOO_LONG;
        result.crc = begin.crc;
        copy_reported(profile);
    }
}

static void rx_end(uint8_t profile) {
    if (!clip.rx.active || profile != clip.origin) {
        return;
    }

    copy_reported(profile);
    result.owed = true;
    result.profile = profile;
    result.crc = clip.rx.crc;
    result.code = clip_rx_end(&clip.rx);

    if (result.code != CLIP_RESULT_OK) {
        LOG_WRN("clip from profile %d rejected (%d)", profile, result.code);
        clip_wipe();
        return;
    }

    clip.valid = true;
    clip.len = clip.rx.expected;
    clip.crc = clip.rx.crc;
    clip.typable = !clip.opaque && clip_has_keys();
    clip.generation++;
    clip_restart_expiry();
    LOG_DBG("clip of %d bytes from profile %d", clip.len, profile);
}

static void rx_hold(uint8_t profile, const uint8_t *frame, uint16_t len) {
    uint8_t flags = len >= CLIP_HOLD_LEN ? frame[1] : 0;

    if (flags & CLIP_HOLD_OFF) {
        if (fetch.active && fetch.profile == profile) {
            fetch.active = false;
        }
        return;
    }

    /* HOLD applies only to an opaque clip from another computer. There is
     * nothing to fetch for text, nor for a copy made on the helper's own
     * computer, and a paste is never held up for either. */
    if (!(clip.valid || clip.rx.active) || !clip.opaque || clip.origin == profile ||
        !(helpers_opaque & BIT(profile))) {
        return;
    }

    /* A helper that was given up on for being slow to answer is back, and it
     * has the clip in hand, or it would not be fetching. */
    if (!(helpers & BIT(profile))) {
        helpers |= BIT(profile);
        if (clip.valid) {
            delivery.active = true;
            delivery.profile = profile;
            delivery.generation = clip.generation;
            delivery.phase = DELIVER_AWAIT_ACK;
        }
    }

    fetch.active = true;
    fetch.profile = profile;
    fetch.soon = flags & CLIP_HOLD_SOON;
    fetch.until = k_uptime_get() + CLIP_HOLD_LAPSE_MS;
}

/* Forgets the helper on `profile`. Caller holds `lock`. */
static void helper_gone(uint8_t profile) {
    helpers &= ~BIT(profile);
    helpers_opaque &= ~BIT(profile);
    if (fetch.active && fetch.profile == profile) {
        fetch.active = false;
    }
    if (relay.owed && relay.from == profile) {
        relay.owed = false;
    }
}

static void rx_frame(uint8_t profile, const uint8_t *frame, uint16_t len) {
    switch (frame[0]) {
    case CLIP_FRAME_HELLO:
        helper_gone(profile);
        helpers |= BIT(profile);
        if (len >= 2 && frame[1] >= 2) {
            helpers_opaque |= BIT(profile);
        }
        status_owed |= BIT(profile);
        /* A helper that has just started has not seen anything sent to its
         * predecessor, so let the clip be offered again. */
        if (delivery.active && delivery.profile == profile) {
            delivery.active = false;
        }
        break;

    case CLIP_FRAME_BYE:
        helper_gone(profile);
        copy_reported(profile);
        break;

    case CLIP_FRAME_BEGIN:
        rx_begin(profile, frame, len);
        break;

    case CLIP_FRAME_DATA: {
        uint16_t offset;
        const uint8_t *payload;
        int payload_len = clip_parse_data(frame, len, &offset, &payload);

        if (payload_len >= 0 && profile == clip.origin) {
            clip_rx_data(&clip.rx, offset, payload, payload_len);
        }
        break;
    }

    case CLIP_FRAME_END:
        rx_end(profile);
        break;

    case CLIP_FRAME_CLEAR:
        clip_wipe();
        copy_reported(profile);
        break;

    case CLIP_FRAME_ACK: {
        uint32_t crc;

        if (clip_parse_ack(frame, len, &crc) && clip.valid && crc == clip.crc) {
            clip.delivered |= BIT(profile);
        }
        /* Whichever clip it was for, the helper is done fetching. */
        if (fetch.active && fetch.profile == profile) {
            fetch.active = false;
        }
        break;
    }

    case CLIP_FRAME_HOLD:
        rx_hold(profile, frame, len);
        break;

    case CLIP_FRAME_RELAY:
        if (len <= CLIP_RELAY_MAX) {
            relay.owed = true;
            relay.from = profile;
            relay.to = -1;
            relay.len = (uint8_t)len;
            memcpy(relay.frame, frame, len);

            /* Word for the computer the clip came from is addressed now. The
             * sender's next frame may begin a clip of its own, and by the
             * time this is passed on the clip would say it came from there. */
            if ((clip.valid || clip.rx.active) && profile != clip.origin) {
                relay.to = (int8_t)clip.origin;
                clip.requester = (int8_t)profile;
            }
        }
        break;

    default:
        LOG_DBG("unknown frame 0x%02x", frame[0]);
        break;
    }
}

static ssize_t rx_write(struct bt_conn *conn, const struct bt_gatt_attr *attr, const void *buf,
                        uint16_t len, uint16_t offset, uint8_t flags) {
    ARG_UNUSED(attr);

    if (flags & BT_GATT_WRITE_FLAG_PREPARE) {
        return 0;
    }
    if (offset != 0) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_OFFSET);
    }
    if (len == 0) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }

    /* An encrypted link is not enough on its own: the clip is tracked per
     * profile, so the writer has to be one. */
    int profile = zmk_ble_profile_index(bt_conn_get_dst(conn));
    if (profile < 0) {
        return BT_GATT_ERR(BT_ATT_ERR_WRITE_NOT_PERMITTED);
    }

    k_mutex_lock(&lock, K_FOREVER);
    rx_frame((uint8_t)profile, buf, len);
    k_mutex_unlock(&lock);

    k_work_submit(&evaluate_work);
    return len;
}

/* Which profile dropped is not worked out here. A profile whose bond was just
 * cleared no longer maps from its address, so `evaluate` instead checks every
 * profile against what is connected. */
static void on_disconnected(struct bt_conn *conn, uint8_t reason) {
    ARG_UNUSED(conn);
    ARG_UNUSED(reason);

    k_work_submit(&evaluate_work);
}

BT_CONN_CB_DEFINE(clipboard_conn_callbacks) = {
    .disconnected = on_disconnected,
};

/* Notifies one frame to the host on `profile`. Called without `lock`. */
static int notify_profile(uint8_t profile, const uint8_t *frame, size_t len) {
    struct bt_conn *conn = bt_conn_lookup_addr_le(BT_ID_DEFAULT, zmk_ble_profile_address(profile));

    if (!conn) {
        return -ENOTCONN;
    }

    int err = bt_gatt_notify(conn, TX_ATTR, frame, len);

    bt_conn_unref(conn);
    return err;
}

static bool is_backpressure(int err) {
    return err == -ENOMEM || err == -ENOBUFS || err == -EAGAIN;
}

static size_t tx_frame_cap(uint8_t profile) {
    struct bt_conn *conn = bt_conn_lookup_addr_le(BT_ID_DEFAULT, zmk_ble_profile_address(profile));
    size_t cap = 0;

    if (conn) {
        uint16_t mtu = bt_gatt_get_mtu(conn);

        /* ATT spends three bytes of the MTU on the notification header. */
        if (mtu > 3) {
            cap = MIN((size_t)mtu - 3, TX_FRAME_MAX);
        }
        bt_conn_unref(conn);
    }

    return cap;
}

/* ---- Keystroke job ---- */

static void send_keyboard_report(void) {
    int err = zmk_endpoint_send_report(HID_USAGE_KEY);

    if (err < 0) {
        LOG_WRN("failed to send report (%d)", err);
    }
}

/* How far apart to space reports on the selected endpoint.
 *
 * Over Bluetooth ZMK queues reports and drops the oldest when the queue
 * fills, so they must not be produced faster than the link carries them. One
 * per connection interval, with a little slack, cannot outrun it. */
static k_timeout_t report_interval(void) {
    uint32_t ms = CONFIG_ZMK_CLIPBOARD_TYPE_DELAY_MS;

    if (zmk_endpoint_get_selected().transport == ZMK_TRANSPORT_BLE) {
        struct bt_conn *conn = zmk_ble_active_profile_conn();
        struct bt_conn_info info;

        if (conn) {
            if (bt_conn_get_info(conn, &info) == 0) {
                /* The interval is in units of 1.25 ms. */
                ms = MAX(ms, (info.le.interval * 5U) / 4U + 2U);
            }
            bt_conn_unref(conn);
        }
    }

    return K_MSEC(ms);
}

/* Raises the held key events again, to the listeners after this one. */
static void release_held(void) {
    uint8_t count = held_count;

    held_count = 0;
    for (uint8_t i = 0; i < count; i++) {
        ZMK_EVENT_RAISE_AFTER(held[i], clipboard);
    }
}

static void job_finish(void) {
    if (job.kind == JOB_NONE) {
        return;
    }

    if (job.key_down) {
        zmk_hid_keyboard_release(job.usage);
        zmk_hid_implicit_modifiers_release();
        job.key_down = false;
    }
    if (job.kind == JOB_TYPE) {
        zmk_hid_masked_modifiers_clear();
    }
    send_keyboard_report();

    memset(job.keys, 0, sizeof(job.keys));
    job.kind = JOB_NONE;
    k_work_cancel_delayable(&job_work);

    release_held();
}

/* Presses `usage`. A key the job is still holding comes up in the same report. */
static void job_press(uint8_t usage, uint8_t mods) {
    if (job.key_down) {
        zmk_hid_keyboard_release(job.usage);
    }
    zmk_hid_implicit_modifiers_press(mods);
    zmk_hid_keyboard_press(usage);
    send_keyboard_report();
    job.usage = usage;
    job.usage_mods = mods;
    job.key_down = true;
}

static void job_release(void) {
    zmk_hid_keyboard_release(job.usage);
    zmk_hid_implicit_modifiers_release();
    send_keyboard_report();
    job.key_down = false;
}

/* Types the clip of the given generation out on the selected endpoint.
 *
 * The paste that triggered this is still being held, so the modifiers are
 * masked out of the report for the duration. Without that every character
 * would arrive as a Cmd or Ctrl shortcut. */
static void job_start_typing(uint16_t generation) {
    job_finish();

    job.kind = JOB_TYPE;
    job.generation = generation;
    job.pos = 0;
    job.key_count = 0;
    job.key_index = 0;
    job.interval = report_interval();

    zmk_hid_masked_modifiers_set(MODS_ALL);
    send_keyboard_report();
    k_work_reschedule(&job_work, job.interval);
}

/* Replays a swallowed paste as the host's own paste shortcut. */
static void job_start_paste(uint8_t mods) {
    job_finish();

    job.kind = JOB_PASTE;
    job.mods = mods;
    job.interval = report_interval();
    k_work_reschedule(&job_work, K_NO_WAIT);
}

/* The next keystroke of the clip being typed, or false once it is finished or
 * the clip has been replaced or wiped underneath the job. It stays next until
 * `key_index` is moved past it. */
static bool job_peek_key(struct clip_key *key) {
    bool found = false;

    k_mutex_lock(&lock, K_FOREVER);
    if (clip.valid && clip.generation == job.generation) {
        while (job.key_index >= job.key_count && job.pos < clip.len) {
            job.key_count = clip_text_next(clip.buf, clip.len, &job.pos, job.keys);
            job.key_index = 0;
        }
        if (job.key_index < job.key_count) {
            *key = job.keys[job.key_index];
            found = true;
        }
    }
    k_mutex_unlock(&lock);

    return found;
}

/* Whether `key` can go down in the report that lets go of the key the job is
 * holding, which makes a character one report rather than two. It cannot if it
 * is the same key, since the host would never see it go down again, or if a
 * modifier comes up with it: hosts differ on which of the two they act on
 * first, and Shift can land on the next character. */
static bool job_can_roll(const struct clip_key *key, uint8_t mods) {
    return key->usage != job.usage && !(job.usage_mods & ~mods);
}

static void job_step(struct k_work *work) {
    struct clip_key key;

    ARG_UNUSED(work);

    switch (job.kind) {
    case JOB_PASTE:
        if (job.key_down) {
            job_finish();
            break;
        }
        job_press(HID_USAGE_KEY_KEYBOARD_V, job.mods);
        k_work_reschedule(&job_work, job.interval);
        break;

    case JOB_TYPE: {
        if (!job_peek_key(&key)) {
            job_finish();
            break;
        }

        uint8_t mods = key.shift ? MOD_LSFT : 0;

        if (job.key_down && !job_can_roll(&key, mods)) {
            job_release();
        } else {
            job.key_index++;
            job_press(key.usage, mods);
        }
        k_work_reschedule(&job_work, job.interval);
        break;
    }

    default:
        break;
    }
}

/* ---- Delivery to a helper ---- */

/* Caller holds `lock`. */
static bool delivery_still_wanted(void) {
    struct zmk_endpoint_instance selected = zmk_endpoint_get_selected();

    return delivery.active && clip.valid && delivery.generation == clip.generation &&
           selected.transport == ZMK_TRANSPORT_BLE &&
           selected.ble.profile_index == delivery.profile && (helpers & BIT(delivery.profile));
}

static void deliver(struct k_work *work) {
    ARG_UNUSED(work);

    for (int sent = 0; sent < TX_FRAMES_PER_PASS; sent++) {
        uint8_t frame[TX_FRAME_MAX];
        size_t frame_len = 0;
        uint16_t taken = 0;
        uint8_t profile;

        k_mutex_lock(&lock, K_FOREVER);
        if (!delivery_still_wanted() || delivery.phase == DELIVER_AWAIT_ACK) {
            k_mutex_unlock(&lock);
            return;
        }

        profile = delivery.profile;
        size_t cap = tx_frame_cap(profile);

        switch (delivery.phase) {
        case DELIVER_BEGIN:
            if (cap >= CLIP_BEGIN_LEN) {
                frame_len = clip_encode_begin(frame, clip.opaque ? CLIP_FLAG_OPAQUE : 0,
                                              clip.len, clip.crc);
            }
            break;
        case DELIVER_DATA:
            frame_len =
                clip_encode_data(frame, cap, clip.buf, clip.len, delivery.offset, &taken);
            break;
        default:
            frame[0] = CLIP_FRAME_END;
            frame_len = cap ? 1 : 0;
            break;
        }
        k_mutex_unlock(&lock);

        int err = frame_len ? notify_profile(profile, frame, frame_len) : -ENOTCONN;

        memset(frame, 0, sizeof(frame));

        if (is_backpressure(err)) {
            k_work_reschedule(&deliver_work, TX_RETRY);
            return;
        }

        k_mutex_lock(&lock, K_FOREVER);
        if (err < 0) {
            /* Not subscribed or gone: there is no helper there after all. */
            LOG_DBG("delivery to profile %d failed (%d)", profile, err);
            helper_gone(profile);
            delivery.active = false;
            k_mutex_unlock(&lock);
            k_work_submit(&evaluate_work);
            return;
        }

        if (delivery.active && delivery.profile == profile) {
            switch (delivery.phase) {
            case DELIVER_BEGIN:
                delivery.phase = DELIVER_DATA;
                break;
            case DELIVER_DATA:
                delivery.offset += taken;
                if (delivery.offset >= clip.len) {
                    delivery.phase = DELIVER_END;
                }
                break;
            default:
                delivery.phase = DELIVER_AWAIT_ACK;
                break;
            }
        }
        k_mutex_unlock(&lock);

        /* Frames are reaching the helper, so a paste that is waiting on it
         * gets a fresh allowance rather than timing out mid-transfer. */
        if (pending_paste.active && !pending_paste.timed_out) {
            k_work_reschedule(&paste_timeout_work, K_MSEC(CONFIG_ZMK_CLIPBOARD_ACK_WAIT_MS));
        }
    }

    k_work_reschedule(&deliver_work, K_MSEC(1));
}

/* Sends whichever of `*owed`'s notifications the link will take, leaving the
 * rest owed. Returns false if any are left. */
static bool send_owed(uint8_t *owed, const uint8_t *frame, size_t len) {
    bool done = true;

    for (uint8_t profile = 0; profile < ZMK_BLE_PROFILE_COUNT; profile++) {
        k_mutex_lock(&lock, K_FOREVER);
        bool due = *owed & BIT(profile);
        *owed &= ~BIT(profile);
        k_mutex_unlock(&lock);

        if (due && is_backpressure(notify_profile(profile, frame, len))) {
            k_mutex_lock(&lock, K_FOREVER);
            *owed |= BIT(profile);
            k_mutex_unlock(&lock);
            done = false;
        }
    }

    return done;
}

/* Passes on the datagram in hand to the helper at the other end of the clip
 * from the one that sent it. Returns false if the link would not take it yet. */
static bool send_relay(void) {
    struct zmk_endpoint_instance selected = zmk_endpoint_get_selected();
    uint8_t frame[CLIP_RELAY_MAX];
    int to = -1;

    k_mutex_lock(&lock, K_FOREVER);
    if (!relay.owed) {
        k_mutex_unlock(&lock);
        return true;
    }

    uint8_t from = relay.from;
    size_t len = relay.len;

    memcpy(frame, relay.frame, len);
    relay.owed = false;

    if (relay.to >= 0) {
        to = relay.to;
    } else if ((clip.valid || clip.rx.active) && from == clip.origin) {
        if (clip.requester >= 0) {
            /* An answer, wherever the keyboard has been switched to since. */
            to = clip.requester;
        } else if (selected.transport == ZMK_TRANSPORT_BLE && selected.ble.profile_index != from) {
            to = selected.ble.profile_index;
        }
    }
    if (to >= 0 && !(helpers_opaque & BIT(to))) {
        to = -1;
    }
    k_mutex_unlock(&lock);

    int err = -ENOTCONN;

    if (to >= 0 && tx_frame_cap((uint8_t)to) >= len) {
        err = notify_profile((uint8_t)to, frame, len);
    }

    if (is_backpressure(err)) {
        k_mutex_lock(&lock, K_FOREVER);
        /* Unless a newer one has taken its place in the meantime. */
        if (!relay.owed) {
            relay.owed = true;
        }
        k_mutex_unlock(&lock);
        return false;
    }

    if (err < 0) {
        /* There is nowhere for it to go. Telling the sender only spares it
         * its timeout, so the refusal is not retried if the link is busy. */
        uint8_t refusal[CLIP_RESULT_LEN];

        notify_profile(from, refusal, clip_encode_result(refusal, CLIP_RESULT_UNREACHABLE, 0));
    }

    return true;
}

static void send_owed_replies(void) {
    uint8_t frame[CLIP_RESULT_LEN];
    const uint8_t poke[] = {CLIP_FRAME_POKE};
    bool done = true;

    done &= send_owed(&poke_owed, poke, sizeof(poke));
    done &= send_owed(&status_owed, frame,
                      clip_encode_status(frame, CONFIG_ZMK_CLIPBOARD_MAX_LEN,
                                         CONFIG_ZMK_CLIPBOARD_OPAQUE_MAX_LEN));
    done &= send_relay();

    k_mutex_lock(&lock, K_FOREVER);
    bool owed = result.owed;
    uint8_t profile = result.profile;
    size_t len = clip_encode_result(frame, result.code, result.crc);
    result.owed = false;
    k_mutex_unlock(&lock);

    if (owed && is_backpressure(notify_profile(profile, frame, len))) {
        k_mutex_lock(&lock, K_FOREVER);
        /* Unless a newer result has taken its place in the meantime. */
        result.owed = true;
        k_mutex_unlock(&lock);
        done = false;
    }

    if (!done) {
        k_work_reschedule(&evaluate_retry_work, TX_RETRY);
    }
}

/* ---- Deciding what to do ---- */

/* Drops what is remembered about profiles that are no longer connected: a
 * helper lives and dies with its connection, and a computer that comes back
 * may not be the same one, or may have lost the clip it was given.
 * Caller holds `lock`. */
static void forget_disconnected(void) {
    for (uint8_t profile = 0; profile < ZMK_BLE_PROFILE_COUNT; profile++) {
        if (zmk_ble_profile_is_connected(profile)) {
            continue;
        }

        uint8_t bit = BIT(profile);

        helper_gone(profile);
        status_owed &= ~bit;
        poke_owed &= ~bit;
        clip.delivered &= ~bit;
        if (delivery.active && delivery.profile == profile) {
            delivery.active = false;
        }
        if (result.owed && result.profile == profile) {
            result.owed = false;
        }
        copy_reported(profile);
    }
}

/* Brings delivery and any waiting paste in line with the current state. Runs
 * on the work queue after anything that might have changed the answer. */
static void evaluate(struct k_work *work) {
    enum { RESOLVE_NOTHING, RESOLVE_PASTE, RESOLVE_TYPE, RESOLVE_DROP } resolve = RESOLVE_NOTHING;
    struct zmk_endpoint_instance selected = zmk_endpoint_get_selected();
    uint16_t generation;
    int64_t wait_ms = -1;

    ARG_UNUSED(work);

    k_mutex_lock(&lock, K_FOREVER);
    forget_disconnected();
    k_mutex_unlock(&lock);

    send_owed_replies();

    k_mutex_lock(&lock, K_FOREVER);

    bool to_helper = clip.valid && selected.transport == ZMK_TRANSPORT_BLE &&
                     is_foreign(selected) && (helpers & BIT(selected.ble.profile_index)) &&
                     (!clip.opaque || (helpers_opaque & BIT(selected.ble.profile_index)));
    bool has_it = to_helper && (clip.delivered & BIT(selected.ble.profile_index));
    bool arriving = clip.rx.active && clip.rx.received != rx_seen;

    rx_seen = clip.rx.active ? clip.rx.received : 0;

    if (to_helper && !has_it) {
        uint8_t profile = selected.ble.profile_index;

        if (!delivery.active || delivery.profile != profile ||
            delivery.generation != clip.generation) {
            delivery.active = true;
            delivery.profile = profile;
            delivery.generation = clip.generation;
            delivery.phase = DELIVER_BEGIN;
            delivery.offset = 0;
            /* Whatever the helper there was fetching, it was not this. */
            if (fetch.active && fetch.profile == profile) {
                fetch.active = false;
            }
            k_work_reschedule(&deliver_work, K_NO_WAIT);
        }
    } else {
        delivery.active = false;
    }

    if (pending_paste.active) {
        bool here = fetching(selected);

        if (here && !fetch.soon) {
            /* The helper is at it and will be a while. A paste now would put
             * down whatever the clipboard held before. */
            resolve = RESOLVE_DROP;
        } else if (!pending_paste.timed_out && here) {
            /* The helper will have it in a moment, for as long as it keeps
             * saying so, up to a limit. */
            wait_ms = MAX(MIN(pending_paste.give_up_at, fetch.until) - k_uptime_get(), 0);
        } else if (!pending_paste.timed_out && awaiting_clip(selected)) {
            /* The clip this paste is for has not finished arriving. While it
             * keeps coming, it is waited for. */
            if (arriving) {
                wait_ms = CONFIG_ZMK_CLIPBOARD_ACK_WAIT_MS;
            }
        } else if (here) {
            resolve = RESOLVE_DROP;
        } else if (has_it || !clip.valid || !is_foreign(selected)) {
            /* Either the host now holds the clip or there is nothing to
             * carry, so the paste the user asked for goes through. */
            resolve = RESOLVE_PASTE;
        } else if (!to_helper) {
            resolve = clip.typable ? RESOLVE_TYPE : RESOLVE_PASTE;
        } else if (pending_paste.timed_out) {
            resolve = RESOLVE_PASTE;
        }
    }
    generation = clip.generation;

    k_mutex_unlock(&lock);

    if (resolve == RESOLVE_NOTHING) {
        if (wait_ms >= 0) {
            k_work_reschedule(&paste_timeout_work, K_MSEC(wait_ms));
        }
        return;
    }

    pending_paste.active = false;
    k_work_cancel_delayable(&paste_timeout_work);
    if (resolve == RESOLVE_PASTE) {
        job_start_paste(pending_paste.mods);
    } else if (resolve == RESOLVE_TYPE) {
        job_start_typing(generation);
    } else {
        release_held();
    }
}

static void paste_timed_out(struct k_work *work) {
    struct zmk_endpoint_instance selected = zmk_endpoint_get_selected();

    ARG_UNUSED(work);

    if (!pending_paste.active) {
        return;
    }
    pending_paste.timed_out = true;

    k_mutex_lock(&lock, K_FOREVER);
    if (!fetching(selected) && clip.valid && !awaiting_clip(selected) &&
        selected.transport == ZMK_TRANSPORT_BLE && is_foreign(selected)) {
        /* It was the helper here that was being waited on, and it had its
         * chance. Stop waiting on it for later pastes too, until it says
         * HELLO again. */
        LOG_DBG("no acknowledgement from the helper; typing instead");
        helpers &= ~BIT(selected.ble.profile_index);
    }
    k_mutex_unlock(&lock);

    evaluate(NULL);
}

static void copy_wait_over(struct k_work *work) {
    ARG_UNUSED(work);

    k_mutex_lock(&lock, K_FOREVER);
    expected.active = false;
    k_mutex_unlock(&lock);

    evaluate(NULL);
}

static void expire(struct k_work *work) {
    bool wiped = false;

    ARG_UNUSED(work);

    k_mutex_lock(&lock, K_FOREVER);
    int64_t remaining = clip.expires_at - k_uptime_get();

    if (remaining > 0) {
        /* A newer clip moved the deadline after this run was already queued. */
        k_work_reschedule(&expire_work, K_MSEC(remaining));
    } else if ((job.kind == JOB_TYPE && job.generation == clip.generation) ||
               (remaining > -EXPIRY_GRACE_MS &&
                ((delivery_still_wanted() && delivery.phase != DELIVER_AWAIT_ACK) ||
                 (fetch.active && k_uptime_get() < fetch.until)))) {
        /* A clip is not cut off halfway through being typed or handed to a
         * helper, or while a helper is fetching what it refers to. */
        k_work_reschedule(&expire_work, K_SECONDS(1));
    } else {
        LOG_DBG("clip expired");
        clip_wipe();
        wiped = true;
    }
    k_mutex_unlock(&lock);

    if (wiped) {
        evaluate(NULL);
    }
}

/* ---- Keys ---- */

static bool swallow(uint8_t usage) {
    for (size_t i = 0; i < ARRAY_SIZE(swallowed); i++) {
        if (swallowed[i] == 0) {
            swallowed[i] = usage;
            return true;
        }
    }
    return false;
}

static bool unswallow(uint8_t usage) {
    for (size_t i = 0; i < ARRAY_SIZE(swallowed); i++) {
        if (swallowed[i] == usage) {
            swallowed[i] = 0;
            return true;
        }
    }
    return false;
}

/* A copy or cut shortcut went to the selected computer.
 *
 * If that computer has a helper, it will say what was copied, so the helper
 * is prodded to look now and a paste elsewhere waits a moment for its answer.
 * The clip in hand is kept meanwhile: Ctrl-C in a terminal looks the same
 * from here and copies nothing.
 *
 * If it has none, the newest copy is somewhere the keyboard cannot see, and
 * the clip in hand is stale. */
static void on_local_copy(void) {
    struct zmk_endpoint_instance selected = zmk_endpoint_get_selected();
    bool changed = false;

    if (selected.transport == ZMK_TRANSPORT_NONE) {
        return;
    }

    k_mutex_lock(&lock, K_FOREVER);
    int reporter = copy_reporter(selected);

    if ((clip.valid || clip.rx.active) && (reporter < 0 || is_foreign(selected))) {
        LOG_DBG("copy the clip does not cover; dropping it");
        clip_wipe();
        changed = true;
    }
    if (reporter >= 0) {
        expected.active = true;
        expected.profile = (uint8_t)reporter;
        poke_owed |= BIT(reporter);
        k_work_reschedule(&copy_wait_work, COPY_WAIT);
        changed = true;
    }
    k_mutex_unlock(&lock);

    if (changed) {
        k_work_submit(&evaluate_work);
    }
}

enum paste_action {
    PASTE_PASS, /* leave it to the host */
    PASTE_WAIT, /* the clip is still arriving, or a helper is about to have it or is fetching */
    PASTE_TYPE, /* no helper; type the clip */
};

static enum paste_action decide_paste(uint16_t *generation) {
    struct zmk_endpoint_instance selected = zmk_endpoint_get_selected();
    enum paste_action action = PASTE_PASS;

    k_mutex_lock(&lock, K_FOREVER);
    if (awaiting_clip(selected)) {
        action = PASTE_WAIT;
    } else if (clip.valid && is_foreign(selected)) {
        action = clip.typable ? PASTE_TYPE : PASTE_PASS;

        if (selected.transport == ZMK_TRANSPORT_BLE) {
            uint8_t bit = BIT(selected.ble.profile_index);

            if (clip.delivered & bit) {
                action = PASTE_PASS;
            } else if (helpers & bit) {
                /* Including one that is fetching what the clip refers to;
                 * `evaluate` decides what becomes of the paste then. */
                action = PASTE_WAIT;
            }
        }
    }
    *generation = clip.generation;
    k_mutex_unlock(&lock);

    return action;
}

/* Returns true if the paste was taken over and must not reach the host. */
static bool on_paste(uint8_t mods) {
    uint16_t generation;
    enum paste_action action = intercept_ok ? decide_paste(&generation) : PASTE_PASS;

    if (action == PASTE_PASS || !swallow(HID_USAGE_KEY_KEYBOARD_V)) {
        return false;
    }

    if (action == PASTE_WAIT) {
        pending_paste.active = true;
        pending_paste.timed_out = false;
        pending_paste.mods = mods;
        pending_paste.give_up_at = k_uptime_get() + FETCH_WAIT_MAX_MS;
        k_work_reschedule(&paste_timeout_work, K_MSEC(CONFIG_ZMK_CLIPBOARD_ACK_WAIT_MS));
        k_work_submit(&evaluate_work);
    } else {
        job_start_typing(generation);
    }

    return true;
}

/* Holds a key event back until the paste ahead of it has gone out. */
static bool hold(const struct zmk_keycode_state_changed *ev) {
    if (held_count >= HELD_MAX) {
        return false;
    }
    held[held_count++] = copy_raised_zmk_keycode_state_changed(ev);
    return true;
}

/* Whether these modifiers make C, X and V the clipboard shortcuts. Alt is
 * left out so Cmd-Opt-V and Ctrl-Alt-V keep their own meanings. */
static bool is_paste(uint8_t mods) { return (mods & MODS_COMMAND) && !(mods & MODS_ALT); }

/* The modifiers `ev` will meet once the events held ahead of it have gone
 * out, which the HID state does not show yet. */
static uint8_t mods_after_held(const struct zmk_keycode_state_changed *ev) {
    uint8_t mods = zmk_hid_get_explicit_mods();

    for (uint8_t i = 0; i < held_count; i++) {
        const struct zmk_keycode_state_changed *queued = &held[i].data;

        if (!is_mod(queued->usage_page, queued->keycode)) {
            continue;
        }

        uint8_t bit = BIT(queued->keycode - HID_USAGE_KEY_KEYBOARD_LEFTCONTROL);

        mods = queued->state ? (mods | bit) : (mods & ~bit);
    }

    return mods | ev->implicit_modifiers;
}

/* The queue is full. Keeping the keys in the order they were pressed matters
 * more than the paste they are waiting behind, so that is given up, what was
 * queued goes out, and the event that did not fit follows it. */
static void held_overflow(void) {
    LOG_WRN("too many keys behind a waiting paste; letting them through");

    if (pending_paste.active) {
        pending_paste.active = false;
        k_work_cancel_delayable(&paste_timeout_work);
    }
    if (job.kind != JOB_NONE) {
        job_finish();
    } else {
        release_held();
    }
}

static int on_keycode(const struct zmk_keycode_state_changed *ev) {
    if (ev->usage_page != HID_USAGE_KEY) {
        return ZMK_EV_EVENT_BUBBLE;
    }

    bool mod = is_mod(ev->usage_page, ev->keycode);

    if (!mod && !ev->state && unswallow(ev->keycode)) {
        return ZMK_EV_EVENT_HANDLED;
    }

    /* The key press that stopped a typing job is swallowed: stopping the job
     * was its whole effect. A modifier is let through all the same, since what
     * is typed next while it is held depends on the host having seen it. */
    if (stopper.armed && ev->state && ev->timestamp == stopper.timestamp) {
        stopper.armed = false;
        if (!mod && swallow(ev->keycode)) {
            return ZMK_EV_EVENT_HANDLED;
        }
    }

    /* A paste has been swallowed and has not gone out yet. Everything typed
     * after it queues up behind it, modifiers included, so their order with
     * the keys they modify is kept too. That goes on for as long as anything
     * is queued: a key let past the queue would reach the host ahead of
     * events that came before it. */
    if (pending_paste.active || job.kind == JOB_PASTE || held_count > 0) {
        /* Paste pressed again while the first is still waiting. It is the
         * same request, and queued it would go out as a paste of its own
         * whatever became of the first. */
        if (pending_paste.active && !mod && ev->state &&
            ev->keycode == HID_USAGE_KEY_KEYBOARD_V && is_paste(mods_after_held(ev)) &&
            swallow(ev->keycode)) {
            return ZMK_EV_EVENT_HANDLED;
        }

        if (hold(ev)) {
            return ZMK_EV_EVENT_CAPTURED;
        }
        held_overflow();
    }

    if (mod || !ev->state) {
        return ZMK_EV_EVENT_BUBBLE;
    }

    uint8_t mods = zmk_hid_get_explicit_mods() | ev->implicit_modifiers;

    if (!is_paste(mods)) {
        return ZMK_EV_EVENT_BUBBLE;
    }

    switch (ev->keycode) {
    case HID_USAGE_KEY_KEYBOARD_C:
    case HID_USAGE_KEY_KEYBOARD_X:
        on_local_copy();
        break;
    case HID_USAGE_KEY_KEYBOARD_V:
        if (on_paste(mods)) {
            return ZMK_EV_EVENT_HANDLED;
        }
        break;
    default:
        break;
    }

    return ZMK_EV_EVENT_BUBBLE;
}

/* Any key going down stops a job that is emitting keystrokes.
 *
 * It is the way out when the wrong thing, or far too much of it, is going
 * into the wrong window. It is also what keeps a job from being caught with a
 * key down by a profile switch: ZMK sends the release that follows to the new
 * profile, and the old computer would be left with the key held. Watching
 * positions rather than keycodes means the layer key that leads to the
 * profile keys, which produces no keycode, stops the job before they act. */
static void on_position_pressed(const struct zmk_position_state_changed *ev) {
    switch (job.kind) {
    case JOB_TYPE:
        job_finish();
        stopper.armed = true;
        stopper.timestamp = ev->timestamp;
        break;
    case JOB_PASTE:
        /* Finishing the tap early is all there is to stop. */
        job_finish();
        break;
    default:
        break;
    }
}

static int clipboard_listener(const zmk_event_t *eh) {
    const struct zmk_keycode_state_changed *key = as_zmk_keycode_state_changed(eh);
    const struct zmk_position_state_changed *position = as_zmk_position_state_changed(eh);

    if (key) {
        return on_keycode(key);
    }

    if (position) {
        if (position->state) {
            on_position_pressed(position);
        }
        return ZMK_EV_EVENT_BUBBLE;
    }

    if (as_zmk_endpoint_changed(eh)) {
        /* Whatever was in flight was meant for the endpoint just left. */
        job_finish();
        pending_paste.active = false;
        k_work_cancel_delayable(&paste_timeout_work);
        release_held();
        k_work_submit(&evaluate_work);
    }

    return ZMK_EV_EVENT_BUBBLE;
}

extern struct zmk_event_subscription __event_subscriptions_start[];
extern struct zmk_event_subscription __event_subscriptions_end[];
extern const struct zmk_listener zmk_listener_hid_listener;

/* Listeners run in link order. Swallowing a paste only works from in front of
 * the listener that turns key events into HID reports. */
static bool runs_before_hid_listener(void) {
    for (struct zmk_event_subscription *sub = __event_subscriptions_start;
         sub < __event_subscriptions_end; sub++) {
        if (sub->event_type != &zmk_event_zmk_keycode_state_changed) {
            continue;
        }
        if (sub->listener == &zmk_listener_clipboard) {
            return true;
        }
        if (sub->listener == &zmk_listener_hid_listener) {
            return false;
        }
    }
    return false;
}

static int clipboard_init(void) {
    clip_rx_init(&clip.rx, clip.buf, sizeof(clip.buf));
    clip.requester = -1;

    intercept_ok = runs_before_hid_listener();
    if (!intercept_ok) {
        LOG_ERR("clipboard listener runs after the HID listener; typed paste is disabled");
    }

    return 0;
}

SYS_INIT(clipboard_init, APPLICATION, CONFIG_APPLICATION_INIT_PRIORITY);
