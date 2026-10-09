/*
 * Copyright (c) 2026 M0110 ZMK Driver
 * SPDX-License-Identifier: MIT
 *
 * The settings calls profile_report.c makes. A test defines settings_save_one
 * and reaches the handler through fake_settings_<name>.
 */

#pragma once

#include "fake.h"

typedef ssize_t (*settings_read_cb)(void *cb_arg, void *data, size_t len);

struct fake_settings_handler {
    const char *subtree;
    int (*set)(const char *key, size_t len, settings_read_cb read_cb, void *cb_arg);
};

#define SETTINGS_STATIC_HANDLER_DEFINE(name, subtree, get, set, commit, export)                    \
    static const struct fake_settings_handler fake_settings_##name = {subtree, set}

int settings_save_one(const char *name, const void *value, size_t val_len);
