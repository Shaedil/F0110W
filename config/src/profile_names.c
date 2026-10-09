/*
 * Copyright (c) 2026 M0110 ZMK Driver
 * SPDX-License-Identifier: MIT
 */

#include "profile_names.h"

#include <errno.h>
#include <string.h>

/* Numbers go up to one per profile, so this is ample. */
#define NUMBER_MAX 31

bool pname_valid(const uint8_t *text, size_t len) {
    if (len > PNAME_MAX) {
        return false;
    }
    for (size_t i = 0; i < len; i++) {
        if (text[i] < 0x20 || text[i] == 0x7F) {
            return false;
        }
    }
    return true;
}

/* -1 if `name` is not `base`, 0 if it is exactly `base`, or n for "base n". */
static int numbered_as(const struct pname *name, const uint8_t *base, size_t len) {
    if (name->len < len || memcmp(name->text, base, len) != 0) {
        return -1;
    }
    if (name->len == len) {
        return 0;
    }

    size_t digits = name->len - len - 1;
    if (name->text[len] != ' ' || digits < 1 || digits > 2 || name->text[len + 1] == '0') {
        return -1;
    }

    int n = 0;
    for (size_t i = len + 1; i < name->len; i++) {
        if (name->text[i] < '0' || name->text[i] > '9') {
            return -1;
        }
        n = n * 10 + (name->text[i] - '0');
    }
    return n <= NUMBER_MAX ? n : -1;
}

static int lowest_free(uint32_t *taken) {
    for (int n = 1; n <= NUMBER_MAX; n++) {
        if (!(*taken & (1UL << n))) {
            *taken |= 1UL << n;
            return n;
        }
    }
    return -1;
}

static void set_numbered(struct pname *name, const uint8_t *base, size_t len, int n) {
    memcpy(name->text, base, len);
    name->len = (uint8_t)len;
    name->text[name->len++] = ' ';
    if (n >= 10) {
        name->text[name->len++] = (char)('0' + n / 10);
    }
    name->text[name->len++] = (char)('0' + n % 10);
}

int pname_auto(struct pname *names, int count, int index, const uint8_t *base, size_t len) {
    if (index < 0 || index >= count || count > NUMBER_MAX || len == 0 || len > PNAME_AUTO_MAX ||
        !pname_valid(base, len)) {
        return -EINVAL;
    }
    if (names[index].len > 0) {
        return 0;
    }

    uint32_t taken = 0;
    uint32_t bare = 0;
    for (int i = 0; i < count; i++) {
        if (i == index) {
            continue;
        }
        int n = numbered_as(&names[i], base, len);
        if (n == 0) {
            bare |= 1UL << i;
        } else if (n > 0) {
            taken |= 1UL << n;
        }
    }

    if (!bare && !taken) {
        memcpy(names[index].text, base, len);
        names[index].len = (uint8_t)len;
        return 1 << index;
    }

    int changed = 0;
    for (int i = 0; i < count; i++) {
        if (bare & (1UL << i)) {
            set_numbered(&names[i], base, len, lowest_free(&taken));
            changed |= 1 << i;
        }
    }
    set_numbered(&names[index], base, len, lowest_free(&taken));
    return changed | 1 << index;
}

size_t pname_encode(const struct pname *names, int count, uint8_t *out, size_t cap) {
    size_t need = 2;
    for (int i = 0; i < count; i++) {
        need += 1 + names[i].len;
    }
    if (need > cap) {
        return 0;
    }

    size_t at = 0;
    out[at++] = PNAME_FORMAT;
    out[at++] = (uint8_t)count;
    for (int i = 0; i < count; i++) {
        out[at++] = names[i].len;
        memcpy(&out[at], names[i].text, names[i].len);
        at += names[i].len;
    }
    return at;
}
