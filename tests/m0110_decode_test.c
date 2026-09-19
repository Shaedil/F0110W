/*
 * Copyright (c) 2026 Shaedil
 * SPDX-License-Identifier: MIT
 *
 * Host-side tests for the M0110 wire decoder.
 */

#include <stdio.h>
#include <string.h>

#include "../config/drivers/input/m0110_decode.h"
#include "m0110_decode_vectors.h"

static int failures;

static uint8_t as_scancode(const struct m0110_key_event *event) {
    return (uint8_t)(event->code | (event->released ? 0x80 : 0x00));
}

static void print_codes(const uint8_t *codes, int len) {
    if (len == 0) {
        printf("(none)");
        return;
    }

    for (int i = 0; i < len; i++) {
        printf("%s%02X", i ? " " : "", codes[i]);
    }
}

static void run_vector(const struct m0110_vector *vector) {
    struct m0110_decoder decoder;
    struct m0110_key_event event;
    uint8_t actual[16];
    int actual_len = 0;

    m0110_decoder_reset(&decoder);

    for (int i = 0; i < vector->input_len; i++) {
        m0110_decoder_feed(&decoder, vector->input[i]);

        while (m0110_decoder_next(&decoder, &event)) {
            if (actual_len < (int)sizeof(actual)) {
                actual[actual_len++] = as_scancode(&event);
            }
        }
    }

    if (vector->truncated) {
        m0110_decoder_interrupted(&decoder);

        while (m0110_decoder_next(&decoder, &event)) {
            if (actual_len < (int)sizeof(actual)) {
                actual[actual_len++] = as_scancode(&event);
            }
        }
    }

    if (actual_len == vector->expected_len &&
        memcmp(actual, vector->expected, (size_t)actual_len) == 0) {
        return;
    }

    failures++;
    printf("FAIL  %s\n        expected ", vector->name);
    print_codes(vector->expected, vector->expected_len);
    printf("\n        got      ");
    print_codes(actual, actual_len);
    printf("\n");
}

static void test_recovers_after_interruption(void) {
    struct m0110_decoder decoder;
    struct m0110_key_event event;

    m0110_decoder_reset(&decoder);
    m0110_decoder_feed(&decoder, 0x79); // keypad prefix
    m0110_decoder_interrupted(&decoder);

    while (m0110_decoder_next(&decoder, &event)) {
        // drop the shift, if any
    }

    m0110_decoder_feed(&decoder, 0x01); // A

    if (!m0110_decoder_next(&decoder, &event) || as_scancode(&event) != 0x00) {
        failures++;
        printf("FAIL  recovers after interruption\n");
        return;
    }

    if (m0110_decoder_next(&decoder, &event)) {
        failures++;
        printf("FAIL  recovers after interruption: extra events\n");
    }
}

static void test_reports_when_more_bytes_are_needed(void) {
    struct m0110_decoder decoder;

    m0110_decoder_reset(&decoder);

    if (m0110_decoder_feed(&decoder, 0x79) != M0110_DECODE_WANT_BYTE) {
        failures++;
        printf("FAIL  keypad prefix should ask for another byte\n");
    }

    if (m0110_decoder_feed(&decoder, 0x0D) != M0110_DECODE_COMPLETE) {
        failures++;
        printf("FAIL  arrow byte should complete the sequence\n");
    }

    m0110_decoder_reset(&decoder);

    if (m0110_decoder_feed(&decoder, 0x01) != M0110_DECODE_COMPLETE) {
        failures++;
        printf("FAIL  an ordinary key is a complete sequence\n");
    }
}

int main(void) {
    for (int i = 0; i < M0110_VECTOR_COUNT; i++) {
        run_vector(&m0110_vectors[i]);
    }

    test_recovers_after_interruption();
    test_reports_when_more_bytes_are_needed();

    if (failures != 0) {
        printf("\n%d failure%s\n", failures, failures == 1 ? "" : "s");
        return 1;
    }

    printf("%d sequences decoded as expected\n", M0110_VECTOR_COUNT);
    return 0;
}
