/*
 * Copyright (c) 2026 Shaedil
 * SPDX-License-Identifier: MIT
 *
 * Wire sequences and the key events they represent.
 */

#ifndef M0110_DECODE_VECTORS_H_
#define M0110_DECODE_VECTORS_H_

#include <stdbool.h>
#include <stdint.h>

struct m0110_vector {
    const char *name;
    uint8_t input[6];
    uint8_t input_len;
    uint8_t expected[6];
    uint8_t expected_len;
    bool truncated;
};

static const struct m0110_vector m0110_vectors[] = {
    { "A press",            { 0x01 },              1, { 0x00 },             1, false },
    { "A release",          { 0x81 },              1, { 0x80 },             1, false },
    { "Space press",        { 0x63 },              1, { 0x31 },             1, false },
    { "Caps latch",         { 0x73 },              1, { 0x39 },             1, false },
    { "Caps unlatch",       { 0xF3 },              1, { 0xB9 },             1, false },
    { "Left press",         { 0x79, 0x0D },        2, { 0x46 },             1, false },
    { "Right press",        { 0x79, 0x05 },        2, { 0x42 },             1, false },
    { "Up press",           { 0x79, 0x1B },        2, { 0x4D },             1, false },
    { "Down press",         { 0x79, 0x11 },        2, { 0x48 },             1, false },
    { "Keypad 5 press",     { 0x79, 0x2F },        2, { 0x57 },             1, false },
    { "Keypad 5 release",   { 0x79, 0xAF },        2, { 0xD7 },             1, false },
    { "Left release",       { 0x79, 0x8D },        2, { 0xC6, 0xE6 },       2, false },
    { "Up release",         { 0x79, 0x9B },        2, { 0xCD, 0xED },       2, false },
    { "Keypad / press",     { 0x71, 0x79, 0x1B },  3, { 0x6D },             1, false },
    { "Keypad = press",     { 0x71, 0x79, 0x11 },  3, { 0x68 },             1, false },
    { "Keypad + press",     { 0x71, 0x79, 0x0D },  3, { 0x66 },             1, false },
    { "Keypad * press",     { 0x71, 0x79, 0x05 },  3, { 0x62 },             1, false },
    { "Shift up, arrow up",   { 0xF1, 0x79, 0x9B }, 3, { 0xCD, 0xED, 0xB8 }, 3, false },
    { "Shift up, arrow down", { 0xF1, 0x79, 0x1B }, 3, { 0xB8 },             1, false },
    { "Shift down, arrow up", { 0x71, 0x79, 0x9B }, 3, { 0xCD, 0xED },       2, false },
    { "Shift down + keypad 5", { 0x71, 0x79, 0x2F }, 3, { 0x38, 0x57 },      2, false },
    { "Shift up + keypad 5",   { 0xF1, 0x79, 0x2F }, 3, { 0xB8, 0x57 },      2, false },
    { "Shift then A",       { 0x71, 0x01 },        2, { 0x38, 0x00 },       2, false },
    { "Shift then shift",   { 0x71, 0x71, 0x01 },  3, { 0x38, 0x38, 0x00 }, 3, false },
    { "Shift up then A",    { 0xF1, 0x01 },        2, { 0xB8, 0x00 },       2, false },
    { "Prefix then nothing",      { 0x79 },        1, { 0 },                0, true },
    { "Shift then nothing",       { 0x71 },        1, { 0x38 },             1, true },
    { "Shift up then nothing",    { 0xF1 },        1, { 0xB8 },             1, true },
    { "Shift, prefix, nothing",   { 0x71, 0x79 },  2, { 0x38 },             1, true },
};

#define M0110_VECTOR_COUNT ((int)(sizeof(m0110_vectors) / sizeof(m0110_vectors[0])))

#endif /* M0110_DECODE_VECTORS_H_ */
