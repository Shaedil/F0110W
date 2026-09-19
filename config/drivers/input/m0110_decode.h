/*
 * Copyright (c) 2026 Shaedil
 * SPDX-License-Identifier: MIT
 *
 * Apple M0110/M0110A wire-protocol decoding, no I/O.
 */

#ifndef M0110_DECODE_H_
#define M0110_DECODE_H_

#include <stdbool.h>
#include <stdint.h>

// Commands the host can send.
enum m0110_command {
    M0110_CMD_INQUIRY = 0x10,   // next transition, blocking to ~250 ms
    M0110_CMD_INSTANT = 0x14,   // next transition if already queued
    M0110_CMD_MODEL = 0x16,     // one model byte
    M0110_CMD_SELF_TEST = 0x36, // pass/fail byte
};

/*
 * Reply bytes that mean something other than "this key moved".
 * Shift is in this list because it leads needs state
 */
enum m0110_reply {
    M0110_REPLY_NO_EVENT = 0x7B,   // nothing pending
    M0110_REPLY_PAD_PREFIX = 0x79, // next byte is keypad or arrow
    M0110_REPLY_SHIFT = 0x71,      // shift transition, or a calc-key marker
    M0110_REPLY_TEST_PASS = 0x7D,
    M0110_REPLY_TEST_FAIL = 0x77,
};

// Base of each block of the scancode space.
#define M0110_BLOCK_PAD 0x40
#define M0110_BLOCK_CALC 0x60

// Caps Lock, whose switch latches instead of springing back.
#define M0110_CODE_CAPS_LOCK 0x39

// One key moving one direction.
struct m0110_key_event {
    uint8_t code;
    bool released;
};

// What the caller should do after handing over a byte.
enum m0110_decode_result {
    M0110_DECODE_COMPLETE,  // sequence ended; ask again with INQUIRY
    M0110_DECODE_WANT_BYTE, // sequence unfinished; ask with INSTANT
};

// Deepest sequence is shift + keypad prefix + arrow release, worth 3 events.
#define M0110_DECODE_EVENT_CAPACITY 4

struct m0110_decoder {
    uint8_t stage;      // how far into a sequence currently
    uint8_t shift_wire; // a shift byte not committed to yet
    uint8_t deferred;   // byte to replay as a fresh sequence
    bool has_deferred;
    struct m0110_key_event events[M0110_DECODE_EVENT_CAPACITY];
    uint8_t head;
    uint8_t count;
};

// Discard all state, including any events not yet collected.
void m0110_decoder_reset(struct m0110_decoder *decoder);

// Hand the decoder one byte of a key transition.
enum m0110_decode_result m0110_decoder_feed(struct m0110_decoder *decoder, uint8_t wire);

// Tell the decoder that a byte it asked for is not coming.
void m0110_decoder_interrupted(struct m0110_decoder *decoder);

// Collect one decoded event. False when there are none left.
bool m0110_decoder_next(struct m0110_decoder *decoder, struct m0110_key_event *out);

#endif // M0110_DECODE_H_
