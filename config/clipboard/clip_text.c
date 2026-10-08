/*
 * Copyright (c) 2026 M0110 ZMK Driver
 * SPDX-License-Identifier: MIT
 */

#include "clip_text.h"

#define KEY_A 0x04
#define KEY_1 0x1E
#define KEY_0 0x27
#define KEY_ENTER 0x28
#define KEY_TAB 0x2B
#define KEY_SPACE 0x2C

/* Punctuation on a US layout: the unshifted character, the shifted one, and
 * the key that carries both. */
static const struct {
    char plain;
    char shifted;
    uint8_t usage;
} punctuation[] = {
    {'-', '_', 0x2D}, {'=', '+', 0x2E}, {'[', '{', 0x2F}, {']', '}', 0x30},
    {'\\', '|', 0x31}, {';', ':', 0x33}, {'\'', '"', 0x34}, {'`', '~', 0x35},
    {',', '<', 0x36}, {'.', '>', 0x37}, {'/', '?', 0x38},
};

/* The characters above the digit row, indexed by digit key 1..9 then 0. */
static const char shifted_digits[] = "!@#$%^&*()";

static bool ascii_key(char c, struct clip_key *key) {
    if (c >= 'a' && c <= 'z') {
        *key = (struct clip_key){.usage = (uint8_t)(KEY_A + (c - 'a')), .shift = false};
        return true;
    }
    if (c >= 'A' && c <= 'Z') {
        *key = (struct clip_key){.usage = (uint8_t)(KEY_A + (c - 'A')), .shift = true};
        return true;
    }
    if (c >= '1' && c <= '9') {
        *key = (struct clip_key){.usage = (uint8_t)(KEY_1 + (c - '1')), .shift = false};
        return true;
    }

    switch (c) {
    case '0':
        *key = (struct clip_key){.usage = KEY_0, .shift = false};
        return true;
    case '\n':
        *key = (struct clip_key){.usage = KEY_ENTER, .shift = false};
        return true;
    case '\t':
        *key = (struct clip_key){.usage = KEY_TAB, .shift = false};
        return true;
    case ' ':
        *key = (struct clip_key){.usage = KEY_SPACE, .shift = false};
        return true;
    default:
        break;
    }

    for (size_t i = 0; i < sizeof(shifted_digits) - 1; i++) {
        if (c == shifted_digits[i]) {
            *key = (struct clip_key){.usage = (uint8_t)(KEY_1 + i), .shift = true};
            return true;
        }
    }

    for (size_t i = 0; i < sizeof(punctuation) / sizeof(punctuation[0]); i++) {
        if (c == punctuation[i].plain || c == punctuation[i].shifted) {
            *key = (struct clip_key){.usage = punctuation[i].usage,
                                     .shift = c == punctuation[i].shifted};
            return true;
        }
    }

    return false;
}

/* U+00C0..U+00FF, each folded to its base letter. Entries that need two
 * letters, or have no letter at all, are zero here and handled by hand. */
static const char latin1_fold[64 + 1] = "AAAAAA\0CEEEEIIIIDNOOOOO\0OUUUUY\0\0"
                                        "aaaaaa\0ceeeeiiiidnooooo\0ouuuuy\0y";

/* The ASCII spelling of a code point that has no key of its own, or NULL.
 *
 * Typographic punctuation, which word processors and web pages substitute for
 * the plain kind, becomes its ASCII form and loses nothing a reader would
 * miss. Accented Latin letters lose their accent, which is wrong but still
 * legible; dropping the letter instead would not be. */
static const char *transliterate(uint32_t cp, char single[2]) {
    switch (cp) {
    case 0x2018: /* left single quote */
    case 0x2019: /* right single quote, apostrophe */
    case 0x201A: /* low single quote */
    case 0x2032: /* prime */
        return "'";
    case 0x00AB: /* left guillemet */
    case 0x00BB: /* right guillemet */
    case 0x201C: /* left double quote */
    case 0x201D: /* right double quote */
    case 0x201E: /* low double quote */
    case 0x2033: /* double prime */
        return "\"";
    case 0x2010: /* hyphen */
    case 0x2011: /* non-breaking hyphen */
    case 0x2013: /* en dash */
    case 0x2014: /* em dash */
    case 0x2212: /* minus sign */
        return "-";
    case 0x2026: /* ellipsis */
        return "...";
    case 0x00A0: /* no-break space */
    case 0x2002: /* en space */
    case 0x2003: /* em space */
    case 0x2009: /* thin space */
    case 0x202F: /* narrow no-break space */
        return " ";
    case 0x2022: /* bullet */
    case 0x00D7: /* multiplication sign */
        return "*";
    case 0x00F7: /* division sign */
        return "/";
    case 0x00C6:
        return "AE";
    case 0x00E6:
        return "ae";
    case 0x00DE:
        return "Th";
    case 0x00FE:
        return "th";
    case 0x00DF:
        return "ss";
    default:
        break;
    }

    if (cp >= 0x00C0 && cp <= 0x00FF && latin1_fold[cp - 0x00C0]) {
        single[0] = latin1_fold[cp - 0x00C0];
        single[1] = '\0';
        return single;
    }

    return NULL;
}

/* Decodes one code point. A malformed sequence consumes a single byte and
 * yields U+FFFD, which has no keystroke, so garbage is skipped a byte at a
 * time instead of swallowing the valid text after it. */
static uint32_t decode(const uint8_t *text, size_t len, size_t *pos) {
    uint8_t lead = text[(*pos)++];
    int extra;
    uint32_t cp;

    if (lead < 0x80) {
        return lead;
    } else if ((lead & 0xE0) == 0xC0) {
        extra = 1;
        cp = lead & 0x1F;
    } else if ((lead & 0xF0) == 0xE0) {
        extra = 2;
        cp = lead & 0x0F;
    } else if ((lead & 0xF8) == 0xF0) {
        extra = 3;
        cp = lead & 0x07;
    } else {
        return 0xFFFD;
    }

    if (len - *pos < (size_t)extra) {
        return 0xFFFD;
    }
    for (int i = 0; i < extra; i++) {
        if ((text[*pos + i] & 0xC0) != 0x80) {
            return 0xFFFD;
        }
    }
    for (int i = 0; i < extra; i++) {
        cp = (cp << 6) | (text[(*pos)++] & 0x3F);
    }

    return cp;
}

int clip_text_next(const uint8_t *text, size_t len, size_t *pos,
                   struct clip_key out[CLIP_TEXT_MAX_KEYS]) {
    if (*pos >= len) {
        return 0;
    }

    uint32_t cp = decode(text, len, pos);

    /* CRLF types a single Enter: the CR is skipped and the LF types it. */
    if (cp == '\r') {
        if (*pos < len && text[*pos] == '\n') {
            return 0;
        }
        cp = '\n';
    }

    if (cp < 0x80) {
        return ascii_key((char)cp, &out[0]) ? 1 : 0;
    }

    char single[2];
    const char *ascii = transliterate(cp, single);
    int n = 0;

    while (ascii && ascii[n] && n < CLIP_TEXT_MAX_KEYS) {
        if (!ascii_key(ascii[n], &out[n])) {
            return 0;
        }
        n++;
    }

    return n;
}
