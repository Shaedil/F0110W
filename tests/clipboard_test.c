/*
 * Copyright (c) 2026 M0110 ZMK Driver
 * SPDX-License-Identifier: MIT
 *
 * Host-side tests for the clipboard wire format and the text-to-keystroke map.
 */

#include <stdio.h>
#include <string.h>

#include "../config/clipboard/clip_proto.h"
#include "../config/clipboard/clip_text.h"

static int failures;

#define CHECK(cond)                                                                                \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                                 \
            failures++;                                                                            \
        }                                                                                          \
    } while (0)

/* Types `text` and renders the keystrokes back as characters, so a test reads
 * as "this input comes out as that output". Untypeable input drops out. */
static const char *typed(const char *text, size_t len) {
    static const char plain[] = "abcdefghijklmnopqrstuvwxyz1234567890\n\x1b\b\t -=[]\\#;'`,./";
    static const char shifted[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%^&*()\n\x1b\b\t _+{}|#:\"~<>?";
    static char out[256];
    size_t pos = 0;
    size_t n = 0;

    while (pos < len) {
        struct clip_key keys[CLIP_TEXT_MAX_KEYS];
        size_t before = pos;
        int count = clip_text_next((const uint8_t *)text, len, &pos, keys);

        CHECK(pos > before);
        if (pos <= before) {
            break;
        }

        for (int i = 0; i < count && n < sizeof(out) - 1; i++) {
            int index = keys[i].usage - 0x04;

            CHECK(index >= 0 && index < (int)sizeof(plain) - 1);
            if (index >= 0 && index < (int)sizeof(plain) - 1) {
                out[n++] = keys[i].shift ? shifted[index] : plain[index];
            }
        }
    }

    out[n] = '\0';
    return out;
}

static void check_typed(const char *input, const char *expected) {
    const char *actual = typed(input, strlen(input));

    if (strcmp(actual, expected) != 0) {
        printf("FAIL typing \"%s\": got \"%s\", want \"%s\"\n", input, actual, expected);
        failures++;
    }
}

static void test_text(void) {
    /* Every printable ASCII character survives the round trip. */
    char ascii[96];
    for (int c = 0x20; c < 0x7F; c++) {
        ascii[c - 0x20] = (char)c;
    }
    ascii[0x7F - 0x20] = '\0';
    check_typed(ascii, ascii);

    check_typed("Hello, World!", "Hello, World!");

    /* Line breaks and tabs come out as spaces, so a pasted command does not
     * run by itself. CRLF and a bare CR are each one line break. */
    check_typed("a\tb\nc", "a b c");
    check_typed("one\r\ntwo", "one two");
    check_typed("one\rtwo", "one two");
    check_typed("end\r", "end ");
    check_typed("curl x | sh\r\n", "curl x | sh ");
    check_typed("a\r\n\r\nb", "a  b");
    check_typed("a\n\rb", "a  b");
    for (int c = 1; c < 0x80; c++) {
        const char one[2] = {(char)c, '\0'};
        const char *out = typed(one, 1);

        CHECK(strchr(out, '\n') == NULL && strchr(out, '\t') == NULL);
    }

    /* Typographic punctuation falls back to ASCII. */
    check_typed("\xE2\x80\x9Cquoted\xE2\x80\x9D", "\"quoted\"");
    check_typed("it\xE2\x80\x99s", "it's");
    check_typed("a \xE2\x80\x94 b", "a - b");
    check_typed("wait\xE2\x80\xA6", "wait...");
    check_typed("no\xC2\xA0" "break", "no break");

    /* Accented Latin letters keep their base letter. */
    check_typed("caf\xC3\xA9 na\xC3\xAFve \xC3\x85ngstr\xC3\xB6m", "cafe naive Angstrom");
    check_typed("stra\xC3\x9F" "e \xC3\x86on \xC3\xBEing", "strasse AEon thing");
    check_typed("2\xC3\x97" "3 6\xC3\xB7" "2 \xC2\xABq\xC2\xBB", "2*3 6/2 \"q\"");
    /* The whole U+00C0..U+00FF block comes out as letters and two signs. */
    check_typed("\xC3\x80\xC3\x81\xC3\x82\xC3\x83\xC3\x84\xC3\x85\xC3\x86\xC3\x87"
                "\xC3\x88\xC3\x89\xC3\x8A\xC3\x8B\xC3\x8C\xC3\x8D\xC3\x8E\xC3\x8F"
                "\xC3\x90\xC3\x91\xC3\x92\xC3\x93\xC3\x94\xC3\x95\xC3\x96\xC3\x97"
                "\xC3\x98\xC3\x99\xC3\x9A\xC3\x9B\xC3\x9C\xC3\x9D\xC3\x9E\xC3\x9F",
                "AAAAAAAECEEEEIIIIDNOOOOO*OUUUUYThss");
    check_typed("\xC3\xA0\xC3\xA1\xC3\xA2\xC3\xA3\xC3\xA4\xC3\xA5\xC3\xA6\xC3\xA7"
                "\xC3\xA8\xC3\xA9\xC3\xAA\xC3\xAB\xC3\xAC\xC3\xAD\xC3\xAE\xC3\xAF"
                "\xC3\xB0\xC3\xB1\xC3\xB2\xC3\xB3\xC3\xB4\xC3\xB5\xC3\xB6\xC3\xB7"
                "\xC3\xB8\xC3\xB9\xC3\xBA\xC3\xBB\xC3\xBC\xC3\xBD\xC3\xBE\xC3\xBF",
                "aaaaaaaeceeeeiiiidnooooo/ouuuuythy");

    /* Everything else is skipped without disturbing its neighbours. */
    check_typed("\xE6\x97\xA5\xE6\x9C\xAC", "");
    check_typed("a\xF0\x9F\x98\x80" "b", "ab");
    check_typed("a\x01\x7F" "b", "ab");

    /* Malformed UTF-8: a stray continuation byte, a truncated sequence and a
     * lead byte followed by ASCII all cost only the bad byte. */
    check_typed("a\x80" "b", "ab");
    check_typed("a\xE2\x80", "a");
    check_typed("a\xE2" "bc", "abc");
    check_typed("\xFF\xFE" "ok", "ok");
}

static void test_crc(void) {
    /* The standard check value for CRC-32/ISO-HDLC. */
    CHECK(clip_crc32((const uint8_t *)"123456789", 9) == 0xCBF43926u);
    CHECK(clip_crc32((const uint8_t *)"", 0) == 0);

    /* A piece at a time comes to the same thing. */
    uint32_t state = CLIP_CRC32_INIT;
    state = clip_crc32_update(state, (const uint8_t *)"1234", 4);
    state = clip_crc32_update(state, (const uint8_t *)"", 0);
    state = clip_crc32_update(state, (const uint8_t *)"56789", 5);
    CHECK(~state == 0xCBF43926u);
}

/* Sends `text` through the encoder in frames of at most `frame_cap` bytes and
 * reassembles it, the way the keyboard and a helper talk to each other. */
static enum clip_result transfer(const uint8_t *text, uint16_t len, size_t frame_cap, uint8_t *dest,
                                 uint16_t dest_cap) {
    uint8_t frame[64];
    struct clip_rx rx;
    struct clip_begin begin;

    clip_rx_init(&rx, dest, dest_cap);

    size_t n = clip_encode_begin(frame, CLIP_FLAG_USB_KNOWN, len, clip_crc32(text, len));
    CHECK(n == CLIP_BEGIN_LEN);
    CHECK(clip_parse_begin(frame, n, &begin));
    CHECK(begin.flags == CLIP_FLAG_USB_KNOWN && begin.len == len);

    enum clip_result result = clip_rx_begin(&rx, &begin);
    if (result != CLIP_RESULT_OK) {
        return result;
    }

    uint16_t offset = 0;
    while (offset < len) {
        uint16_t taken;
        uint16_t parsed_offset;
        const uint8_t *payload;

        n = clip_encode_data(frame, frame_cap, text, len, offset, &taken);
        CHECK(n > CLIP_DATA_HEADER_LEN && n <= frame_cap && taken > 0);
        if (taken == 0) {
            break;
        }

        int payload_len = clip_parse_data(frame, n, &parsed_offset, &payload);
        CHECK(payload_len == taken && parsed_offset == offset);
        clip_rx_data(&rx, parsed_offset, payload, (size_t)payload_len);
        offset = (uint16_t)(offset + taken);
    }

    return clip_rx_end(&rx);
}

static void test_transfer(void) {
    uint8_t text[300];
    uint8_t dest[512];

    for (size_t i = 0; i < sizeof(text); i++) {
        text[i] = (uint8_t)(i * 7 + 3);
    }

    /* 20 bytes is what the default ATT MTU leaves for a frame. */
    memset(dest, 0, sizeof(dest));
    CHECK(transfer(text, sizeof(text), 20, dest, sizeof(dest)) == CLIP_RESULT_OK);
    CHECK(memcmp(dest, text, sizeof(text)) == 0);

    CHECK(transfer(text, 1, 20, dest, sizeof(dest)) == CLIP_RESULT_OK);
    CHECK(transfer(text, sizeof(text), 64, dest, sizeof(text)) == CLIP_RESULT_OK);
    CHECK(transfer(text, sizeof(text), 20, dest, sizeof(text) - 1) == CLIP_RESULT_TOO_LONG);
}

static void test_rx_rejects(void) {
    uint8_t dest[32];
    struct clip_rx rx;
    const uint8_t text[] = "0123456789";
    const uint16_t len = sizeof(text) - 1;
    struct clip_begin begin = {.len = len, .crc = clip_crc32(text, len)};

    /* A gap. */
    clip_rx_init(&rx, dest, sizeof(dest));
    CHECK(clip_rx_begin(&rx, &begin) == CLIP_RESULT_OK);
    clip_rx_data(&rx, 0, text, 4);
    clip_rx_data(&rx, 6, &text[6], 4);
    CHECK(clip_rx_end(&rx) == CLIP_RESULT_CORRUPT);

    /* A replayed frame. */
    CHECK(clip_rx_begin(&rx, &begin) == CLIP_RESULT_OK);
    clip_rx_data(&rx, 0, text, 5);
    clip_rx_data(&rx, 0, text, 5);
    clip_rx_data(&rx, 5, &text[5], 5);
    CHECK(clip_rx_end(&rx) == CLIP_RESULT_CORRUPT);

    /* More data than BEGIN announced must not run past the announced length. */
    memset(dest, 0xAA, sizeof(dest));
    CHECK(clip_rx_begin(&rx, &begin) == CLIP_RESULT_OK);
    clip_rx_data(&rx, 0, text, len);
    clip_rx_data(&rx, len, text, len);
    CHECK(dest[len] == 0xAA);
    CHECK(clip_rx_end(&rx) == CLIP_RESULT_CORRUPT);

    /* Short. */
    CHECK(clip_rx_begin(&rx, &begin) == CLIP_RESULT_OK);
    clip_rx_data(&rx, 0, text, 9);
    CHECK(clip_rx_end(&rx) == CLIP_RESULT_CORRUPT);

    /* Right length, wrong bytes. */
    CHECK(clip_rx_begin(&rx, &begin) == CLIP_RESULT_OK);
    clip_rx_data(&rx, 0, (const uint8_t *)"0123456780", len);
    CHECK(clip_rx_end(&rx) == CLIP_RESULT_CORRUPT);

    /* Data and END with no BEGIN, and END twice. */
    clip_rx_init(&rx, dest, sizeof(dest));
    clip_rx_data(&rx, 0, text, len);
    CHECK(clip_rx_end(&rx) == CLIP_RESULT_CORRUPT);
    CHECK(clip_rx_begin(&rx, &begin) == CLIP_RESULT_OK);
    clip_rx_data(&rx, 0, text, len);
    CHECK(clip_rx_end(&rx) == CLIP_RESULT_OK);
    CHECK(clip_rx_end(&rx) == CLIP_RESULT_CORRUPT);

    /* A fresh BEGIN recovers from a poisoned transfer. */
    CHECK(clip_rx_begin(&rx, &begin) == CLIP_RESULT_OK);
    clip_rx_data(&rx, 3, text, 2);
    CHECK(clip_rx_begin(&rx, &begin) == CLIP_RESULT_OK);
    clip_rx_data(&rx, 0, text, len);
    CHECK(clip_rx_end(&rx) == CLIP_RESULT_OK);
}

static void test_frames(void) {
    uint8_t frame[16];
    struct clip_begin begin;
    uint16_t offset;
    const uint8_t *payload;
    uint32_t crc;

    /* Truncated and mistyped frames are refused. */
    clip_encode_begin(frame, 0, 10, 0x12345678u);
    CHECK(!clip_parse_begin(frame, CLIP_BEGIN_LEN - 1, &begin));
    frame[0] = CLIP_FRAME_DATA;
    CHECK(!clip_parse_begin(frame, CLIP_BEGIN_LEN, &begin));
    CHECK(clip_parse_data(frame, 2, &offset, &payload) == -1);
    CHECK(clip_parse_data(frame, CLIP_DATA_HEADER_LEN, &offset, &payload) == 0);

    const uint8_t ack[] = {CLIP_FRAME_ACK, 0x78, 0x56, 0x34, 0x12};
    CHECK(clip_parse_ack(ack, sizeof(ack), &crc) && crc == 0x12345678u);
    CHECK(!clip_parse_ack(ack, sizeof(ack) - 1, &crc));

    CHECK(clip_encode_status(frame, 4096, 0xF000) == CLIP_STATUS_LEN);
    CHECK(frame[0] == CLIP_FRAME_STATUS && frame[1] == CLIP_PROTO_VERSION);
    CHECK(frame[2] == 0x00 && frame[3] == 0x10);
    CHECK(frame[4] == 0x00 && frame[5] == 0xF0);

    CHECK(clip_encode_result(frame, CLIP_RESULT_CORRUPT, 0xA1B2C3D4u) == CLIP_RESULT_LEN);
    CHECK(frame[0] == CLIP_FRAME_RESULT && frame[1] == CLIP_RESULT_CORRUPT);
    CHECK(frame[2] == 0xD4 && frame[5] == 0xA1);
}

int main(void) {
    test_text();
    test_crc();
    test_transfer();
    test_rx_rejects();
    test_frames();

    if (failures) {
        printf("%d failure(s)\n", failures);
        return 1;
    }

    printf("clipboard: ok\n");
    return 0;
}
