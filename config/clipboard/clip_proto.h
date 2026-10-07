/*
 * Copyright (c) 2026 M0110 ZMK Driver
 * SPDX-License-Identifier: MIT
 *
 * Wire format of the clipboard service.
 *
 * One frame per GATT write or notification, first byte the frame type,
 * multi-byte fields little-endian. A clip travels the same way in both
 * directions: BEGIN, then DATA frames in offset order, then END.
 *
 * A clip is either text, which the keyboard can type out on a computer with
 * no helper, or opaque: a message from the helper on one computer to the
 * helper on another, which the keyboard carries without looking inside and
 * never types. Helpers use opaque clips to pass each other what does not fit
 * through a keyboard, such as an image; helper/PROTOCOL.md on the m0110-hud
 * branch has the format they agree on.
 *
 * Version 2 added opaque clips, RELAY, HOLD and the second STATUS field. A
 * version 1 helper still works for text.
 *
 * Nothing here depends on Zephyr, so the host tests build it as is.
 */

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define CLIP_PROTO_VERSION 2

enum clip_frame_type {
    /* Either direction. */
    CLIP_FRAME_BEGIN = 0x01, /* flags:u8 len:u16 crc32:u32 */
    CLIP_FRAME_DATA = 0x02,  /* offset:u16 bytes... */
    CLIP_FRAME_END = 0x03,
    /* bytes...; a datagram for the helper at the other end of the clip. From
     * the computer the clip was copied on it goes to the selected one, and
     * from anywhere else to the one it was copied on. Not stored: if there is
     * no helper there to take it, the sender gets RESULT_UNREACHABLE. */
    CLIP_FRAME_RELAY = 0x08,

    /* Host to keyboard. */
    CLIP_FRAME_CLEAR = 0x04, /* a copy happened here that cannot be carried */
    CLIP_FRAME_HELLO = 0x05, /* version:u8 flags:u8; a helper is listening */
    CLIP_FRAME_ACK = 0x06,   /* crc32:u32; the delivered clip is on the host's clipboard */
    CLIP_FRAME_BYE = 0x07,   /* the helper is going away */
    /* flags:u8; the helper is fetching what an opaque clip refers to, and a
     * paste on its computer must not go through until it has. Lapses unless
     * repeated; see CLIP_HOLD_REPEAT_MS. */
    CLIP_FRAME_HOLD = 0x09,

    /* Keyboard to host. */
    CLIP_FRAME_STATUS = 0x10, /* version:u8 max_len:u16 max_opaque:u16; answers HELLO */
    CLIP_FRAME_RESULT = 0x11, /* code:u8 crc32:u32; answers END, or a RELAY that went nowhere */
    CLIP_FRAME_POKE = 0x12,   /* a copy shortcut was just pressed here; look now */
};

/* BEGIN flags, host to keyboard. Without USB_KNOWN the keyboard cannot tell
 * whether its USB port leads back to the computer the clip came from, and
 * leaves pastes over USB alone. */
#define CLIP_FLAG_USB_KNOWN 0x01
#define CLIP_FLAG_USB_LOCAL 0x02
/* BEGIN flag, either direction: the clip is opaque rather than text. */
#define CLIP_FLAG_OPAQUE 0x04

/* HOLD flags. With SOON the fetch is expected to finish within a moment, and
 * a paste is kept back to wait for it; without, the paste is dropped, since
 * holding the keys behind it for long would look like a dead keyboard. OFF
 * ends the hold at once. */
#define CLIP_HOLD_SOON 0x01
#define CLIP_HOLD_OFF 0x02

/* A hold lapses this long after the last HOLD frame; helpers repeat it at the
 * shorter interval. */
#define CLIP_HOLD_LAPSE_MS 1500
#define CLIP_HOLD_REPEAT_MS 400

/* The longest RELAY frame the keyboard passes on, type byte included. */
#define CLIP_RELAY_MAX 64

enum clip_result {
    CLIP_RESULT_OK = 0,
    CLIP_RESULT_TOO_LONG = 1,
    CLIP_RESULT_CORRUPT = 2,
    CLIP_RESULT_UNREACHABLE = 3,
};

#define CLIP_BEGIN_LEN 8
#define CLIP_DATA_HEADER_LEN 3
#define CLIP_ACK_LEN 5
#define CLIP_STATUS_LEN 6
#define CLIP_HOLD_LEN 2
#define CLIP_RESULT_LEN 6

/* CRC-32 (IEEE 802.3), the same one zlib and every host language ship. */
uint32_t clip_crc32(const uint8_t *data, size_t len);
/* The same, a piece at a time: start from CLIP_CRC32_INIT, and the checksum is
 * the complement of the final state. */
#define CLIP_CRC32_INIT 0xFFFFFFFFu
uint32_t clip_crc32_update(uint32_t state, const uint8_t *data, size_t len);

struct clip_begin {
    uint8_t flags;
    uint16_t len;
    uint32_t crc;
};

bool clip_parse_begin(const uint8_t *frame, size_t frame_len, struct clip_begin *out);
size_t clip_encode_begin(uint8_t *frame, uint8_t flags, uint16_t len, uint32_t crc);

/* Returns the number of payload bytes, or -1 for a malformed frame. */
int clip_parse_data(const uint8_t *frame, size_t frame_len, uint16_t *offset,
                    const uint8_t **payload);
/* Encodes as much of src[offset..len) as fits in frame_cap; returns the frame length. */
size_t clip_encode_data(uint8_t *frame, size_t frame_cap, const uint8_t *src, uint16_t len,
                        uint16_t offset, uint16_t *taken);

bool clip_parse_ack(const uint8_t *frame, size_t frame_len, uint32_t *crc);
size_t clip_encode_status(uint8_t *frame, uint16_t max_len, uint16_t max_opaque);
size_t clip_encode_result(uint8_t *frame, enum clip_result code, uint32_t crc);

/*
 * Reassembly of one incoming clip into a caller-owned buffer.
 *
 * DATA must arrive in order. A gap, an overrun or a checksum mismatch poisons
 * the transfer, and it then fails at END rather than committing a partial clip.
 */
struct clip_rx {
    uint8_t *buf;
    uint16_t cap;
    uint16_t expected;
    uint16_t received;
    uint32_t crc;
    /* Checksum state over what has arrived, kept as it arrives so that END
     * does not have to walk the whole clip on the Bluetooth thread. */
    uint32_t running;
    bool active;
    bool poisoned;
};

void clip_rx_init(struct clip_rx *rx, uint8_t *buf, uint16_t cap);
/* CLIP_RESULT_TOO_LONG leaves the transfer inactive. */
enum clip_result clip_rx_begin(struct clip_rx *rx, const struct clip_begin *begin);
void clip_rx_data(struct clip_rx *rx, uint16_t offset, const uint8_t *payload, size_t len);
/* Ends the transfer; on CLIP_RESULT_OK buf holds `expected` verified bytes. */
enum clip_result clip_rx_end(struct clip_rx *rx);
