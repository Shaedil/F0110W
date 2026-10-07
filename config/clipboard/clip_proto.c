/*
 * Copyright (c) 2026 M0110 ZMK Driver
 * SPDX-License-Identifier: MIT
 */

#include "clip_proto.h"

#include <string.h>

static uint16_t get_le16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }

static uint32_t get_le32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void put_le16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
}

static void put_le32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

/* Bitwise rather than table-driven: it runs over one frame at a time as a clip
 * arrives, and a 1 KiB table would cost more flash than the speed is worth. */
uint32_t clip_crc32_update(uint32_t state, const uint8_t *data, size_t len) {
    for (size_t i = 0; i < len; i++) {
        state ^= data[i];
        for (int bit = 0; bit < 8; bit++) {
            state = (state >> 1) ^ (0xEDB88320u & (0u - (state & 1u)));
        }
    }

    return state;
}

uint32_t clip_crc32(const uint8_t *data, size_t len) {
    return ~clip_crc32_update(CLIP_CRC32_INIT, data, len);
}

bool clip_parse_begin(const uint8_t *frame, size_t frame_len, struct clip_begin *out) {
    if (frame_len < CLIP_BEGIN_LEN || frame[0] != CLIP_FRAME_BEGIN) {
        return false;
    }

    out->flags = frame[1];
    out->len = get_le16(&frame[2]);
    out->crc = get_le32(&frame[4]);
    return true;
}

size_t clip_encode_begin(uint8_t *frame, uint8_t flags, uint16_t len, uint32_t crc) {
    frame[0] = CLIP_FRAME_BEGIN;
    frame[1] = flags;
    put_le16(&frame[2], len);
    put_le32(&frame[4], crc);
    return CLIP_BEGIN_LEN;
}

int clip_parse_data(const uint8_t *frame, size_t frame_len, uint16_t *offset,
                    const uint8_t **payload) {
    if (frame_len < CLIP_DATA_HEADER_LEN || frame[0] != CLIP_FRAME_DATA) {
        return -1;
    }

    *offset = get_le16(&frame[1]);
    *payload = &frame[CLIP_DATA_HEADER_LEN];
    return (int)(frame_len - CLIP_DATA_HEADER_LEN);
}

size_t clip_encode_data(uint8_t *frame, size_t frame_cap, const uint8_t *src, uint16_t len,
                        uint16_t offset, uint16_t *taken) {
    *taken = 0;
    if (frame_cap <= CLIP_DATA_HEADER_LEN || offset >= len) {
        return 0;
    }

    size_t room = frame_cap - CLIP_DATA_HEADER_LEN;
    size_t left = (size_t)(len - offset);
    size_t n = left < room ? left : room;

    frame[0] = CLIP_FRAME_DATA;
    put_le16(&frame[1], offset);
    memcpy(&frame[CLIP_DATA_HEADER_LEN], &src[offset], n);
    *taken = (uint16_t)n;
    return CLIP_DATA_HEADER_LEN + n;
}

bool clip_parse_ack(const uint8_t *frame, size_t frame_len, uint32_t *crc) {
    if (frame_len < CLIP_ACK_LEN || frame[0] != CLIP_FRAME_ACK) {
        return false;
    }

    *crc = get_le32(&frame[1]);
    return true;
}

size_t clip_encode_status(uint8_t *frame, uint16_t max_len, uint16_t max_opaque) {
    frame[0] = CLIP_FRAME_STATUS;
    frame[1] = CLIP_PROTO_VERSION;
    put_le16(&frame[2], max_len);
    put_le16(&frame[4], max_opaque);
    return CLIP_STATUS_LEN;
}

size_t clip_encode_result(uint8_t *frame, enum clip_result code, uint32_t crc) {
    frame[0] = CLIP_FRAME_RESULT;
    frame[1] = (uint8_t)code;
    put_le32(&frame[2], crc);
    return CLIP_RESULT_LEN;
}

void clip_rx_init(struct clip_rx *rx, uint8_t *buf, uint16_t cap) {
    memset(rx, 0, sizeof(*rx));
    rx->buf = buf;
    rx->cap = cap;
}

enum clip_result clip_rx_begin(struct clip_rx *rx, const struct clip_begin *begin) {
    rx->received = 0;
    rx->poisoned = false;
    rx->expected = begin->len;
    rx->crc = begin->crc;
    rx->running = CLIP_CRC32_INIT;
    rx->active = begin->len <= rx->cap;
    return rx->active ? CLIP_RESULT_OK : CLIP_RESULT_TOO_LONG;
}

void clip_rx_data(struct clip_rx *rx, uint16_t offset, const uint8_t *payload, size_t len) {
    if (!rx->active) {
        return;
    }

    if (offset != rx->received || len > (size_t)(rx->expected - rx->received)) {
        rx->poisoned = true;
        return;
    }

    memcpy(&rx->buf[offset], payload, len);
    rx->running = clip_crc32_update(rx->running, payload, len);
    rx->received = (uint16_t)(rx->received + len);
}

enum clip_result clip_rx_end(struct clip_rx *rx) {
    bool ok = rx->active && !rx->poisoned && rx->received == rx->expected &&
              (uint32_t)~rx->running == rx->crc;

    rx->active = false;
    return ok ? CLIP_RESULT_OK : CLIP_RESULT_CORRUPT;
}
