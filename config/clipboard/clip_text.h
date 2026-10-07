/*
 * Copyright (c) 2026 M0110 ZMK Driver
 * SPDX-License-Identifier: MIT
 *
 * Turns clip text into the keystrokes that type it.
 *
 * Only used for a computer with no helper running, where the clip cannot be
 * put on the clipboard and has to arrive as typing. The mapping assumes a US
 * layout on the receiving side, since the keyboard has no way to ask.
 *
 * Nothing here depends on Zephyr, so the host tests build it as is.
 */

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct clip_key {
    uint8_t usage; /* HID keyboard page usage ID */
    bool shift;
};

/* The longest expansion of one code point (an ellipsis is three periods). */
#define CLIP_TEXT_MAX_KEYS 3

/*
 * Decodes the UTF-8 code point at text[*pos], advances *pos past it, and
 * writes the keystrokes for it to out.
 *
 * Returns how many keys were written. Zero means the code point has no
 * keystroke on a US layout and is skipped. *pos always advances while it is
 * below len, so a caller looping on it terminates on malformed input too.
 */
int clip_text_next(const uint8_t *text, size_t len, size_t *pos,
                   struct clip_key out[CLIP_TEXT_MAX_KEYS]);
