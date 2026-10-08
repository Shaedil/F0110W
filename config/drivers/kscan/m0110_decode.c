/*
 * Copyright (c) 2026 Shaedil
 * SPDX-License-Identifier: MIT
 *
 * Apple M0110/M0110A wire-protocol decoding. See m0110_decode.h for the shape
 * of the interface.
 */

#include "m0110_decode.h"

enum m0110_stage {
    STAGE_START,       // nothing pending
    STAGE_PAD,         // saw the keypad prefix
    STAGE_SHIFT,       // saw a shift transition, meaning still undecided
    STAGE_SHIFT_PAD,   // shift then keypad prefix: a calc key, or shift+arrow
};

/*
 * Split a key byte into the key and the direction it moved.
 *
 * The keyboard packs the keycode into bits 6-1, so recovering it takes a mask
 * and a shift. Bit 0 is the frame invariant and carries nothing. The transport
 * has already checked it by the time a byte reaches here.
 */
static struct m0110_key_event split_key_byte(uint8_t wire) {
    struct m0110_key_event event = {
        .code = (uint8_t)((wire & 0x7E) >> 1),
        .released = (wire & 0x80) != 0,
    };
    return event;
}

// The four keys that report as arrows.
static bool code_is_arrow(uint8_t code) {
    switch (code) {
    case 0x0D: // up,    or keypad /
    case 0x08: // down,  or keypad =
    case 0x06: // left,  or keypad +
    case 0x02: // right, or keypad *
        return true;
    default:
        return false;
    }
}

static void emit(struct m0110_decoder *decoder, uint8_t code, bool released) {
    uint8_t slot;

    if (decoder->count >= M0110_DECODE_EVENT_CAPACITY) {
        return;
    }

    slot = (uint8_t)((decoder->head + decoder->count) % M0110_DECODE_EVENT_CAPACITY);
    decoder->events[slot].code = code;
    decoder->events[slot].released = released;
    decoder->count++;
}

/*
 * Hand a byte back to be read again as the start of a fresh sequence.
 * This happens when a shift is just the Shift key: the byte that followed it
 * shouldn't be part of a sequence and has to be decoded again.
 */
static void defer(struct m0110_decoder *decoder, uint8_t wire) {
    decoder->deferred = wire;
    decoder->has_deferred = true;
}

static void commit_shift(struct m0110_decoder *decoder) {
    struct m0110_key_event shift = split_key_byte(decoder->shift_wire);

    emit(decoder, shift.code, shift.released);
}

static void emit_arrow_release(struct m0110_decoder *decoder, uint8_t code) {
    emit(decoder, (uint8_t)(M0110_BLOCK_PAD + code), true);
    emit(decoder, (uint8_t)(M0110_BLOCK_CALC + code), true);
}

static enum m0110_decode_result feed_one(struct m0110_decoder *decoder, uint8_t wire) {
    struct m0110_key_event key;
    bool shift_released;

    switch (decoder->stage) {
    case STAGE_START:
        switch (wire & 0x7F) {
        case M0110_REPLY_PAD_PREFIX:
            decoder->stage = STAGE_PAD;
            return M0110_DECODE_WANT_BYTE;
        case M0110_REPLY_SHIFT:
            decoder->shift_wire = wire;
            decoder->stage = STAGE_SHIFT;
            return M0110_DECODE_WANT_BYTE;
        default:
            key = split_key_byte(wire);
            emit(decoder, key.code, key.released);
            return M0110_DECODE_COMPLETE;
        }

    case STAGE_PAD:
        decoder->stage = STAGE_START;
        key = split_key_byte(wire);
        if (code_is_arrow(key.code) && key.released) {
            emit_arrow_release(decoder, key.code);
        } else {
            emit(decoder, (uint8_t)(M0110_BLOCK_PAD + key.code), key.released);
        }
        return M0110_DECODE_COMPLETE;

    case STAGE_SHIFT:
        if ((wire & 0x7F) == M0110_REPLY_PAD_PREFIX) {
            decoder->stage = STAGE_SHIFT_PAD;
            return M0110_DECODE_WANT_BYTE;
        }
        commit_shift(decoder);
        decoder->stage = STAGE_START;
        defer(decoder, wire);
        return M0110_DECODE_COMPLETE;

    case STAGE_SHIFT_PAD:
    default:
        decoder->stage = STAGE_START;
        key = split_key_byte(wire);
        shift_released = (decoder->shift_wire & 0x80) != 0;

        if (!code_is_arrow(key.code)) {
            commit_shift(decoder);
            emit(decoder, (uint8_t)(M0110_BLOCK_PAD + key.code), key.released);
            return M0110_DECODE_COMPLETE;
        }

        if (shift_released) {
            if (key.released) {
                emit_arrow_release(decoder, key.code);
            }
            commit_shift(decoder);
            return M0110_DECODE_COMPLETE;
        }

        if (key.released) {
            emit_arrow_release(decoder, key.code);
        } else {
            emit(decoder, (uint8_t)(M0110_BLOCK_CALC + key.code), false);
        }
        return M0110_DECODE_COMPLETE;
    }
}

void m0110_decoder_reset(struct m0110_decoder *decoder) {
    decoder->stage = STAGE_START;
    decoder->shift_wire = 0;
    decoder->deferred = 0;
    decoder->has_deferred = false;
    decoder->head = 0;
    decoder->count = 0;
}

enum m0110_decode_result m0110_decoder_feed(struct m0110_decoder *decoder, uint8_t wire) {
    enum m0110_decode_result result = feed_one(decoder, wire);

    while (result == M0110_DECODE_COMPLETE && decoder->has_deferred) {
        uint8_t replay = decoder->deferred;

        decoder->has_deferred = false;
        result = feed_one(decoder, replay);
    }

    return result;
}

void m0110_decoder_interrupted(struct m0110_decoder *decoder) {
    if (decoder->stage == STAGE_SHIFT || decoder->stage == STAGE_SHIFT_PAD) {
        commit_shift(decoder);
    }

    decoder->stage = STAGE_START;
    decoder->deferred = 0;
    decoder->has_deferred = false;
}

bool m0110_decoder_next(struct m0110_decoder *decoder, struct m0110_key_event *out) {
    if (decoder->count == 0) {
        return false;
    }

    *out = decoder->events[decoder->head];
    decoder->head = (uint8_t)((decoder->head + 1) % M0110_DECODE_EVENT_CAPACITY);
    decoder->count--;

    return true;
}
