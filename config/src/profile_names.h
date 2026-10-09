/*
 * Copyright (c) 2026 M0110 ZMK Driver
 * SPDX-License-Identifier: MIT
 *
 * The names computers have given the keyboard's Bluetooth profiles, kept on
 * the keyboard so every computer that pairs with it sees the same ones.
 *
 * A name is up to PNAME_MAX bytes of UTF-8 with no control characters. An
 * empty name means none was given, and a helper shows "Profile N" for it.
 *
 * Nothing here depends on Zephyr, so the host tests build it as is.
 */

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define PNAME_MAX 24

/* The longest name a helper may offer for numbering: room is left for " 99". */
#define PNAME_AUTO_MAX (PNAME_MAX - 3)

struct pname {
    uint8_t len;
    char text[PNAME_MAX];
};

/* Whether `text` can be stored as a name. Empty is allowed. */
bool pname_valid(const uint8_t *text, size_t len);

/*
 * Names profile `index` `base`, unless it already has a name.
 *
 * When another profile already has that name, the profiles that share it are
 * numbered: a lone "MacBook Pro M4" becomes "MacBook Pro M4 1" and the new one
 * "MacBook Pro M4 2". Numbers already taken are kept and the lowest free one is
 * given out.
 *
 * Returns a bit per profile whose name changed, 0 if `index` already had a
 * name, or -EINVAL.
 */
int pname_auto(struct pname *names, int count, int index, const uint8_t *base, size_t len);

/*
 * The names as the characteristic carries them: format:u8 count:u8, then per
 * profile len:u8 and the bytes. Returns the length written, 0 if `cap` is too
 * small.
 */
size_t pname_encode(const struct pname *names, int count, uint8_t *out, size_t cap);

#define PNAME_FORMAT 1
#define PNAME_ENCODED_MAX(count) (2 + (count) * (1 + PNAME_MAX))
