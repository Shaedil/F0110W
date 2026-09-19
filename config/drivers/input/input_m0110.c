/*
 * Copyright (c) 2026 Shaedil
 * SPDX-License-Identifier: MIT
 *
 * Apple M0110/M0110A keyboard converter for ZMK (Zephyr RTOS).
 *
 * This file is the transport half of the driver: it works the two-wire bus,
 * turns bytes into ZMK key positions, and owns the power and error handling
 * around both.  Understanding a stream of bytes as key events belongs to
 * m0110_decode.c, which has no I/O in it and is tested on the host.
 *
 * ZMK wants a matrix and this keyboard has none, only 7-bit scancodes over a
 * wire. The driver invents one: eight columns wide, so a scancode's row is
 * its top bits and its column is its low three. That width is what puts the
 * keypad and calc blocks on whole-row boundaries. See M0110_BLOCK_PAD in
 * m0110_decode.h.
 */

#define DT_DRV_COMPAT zmk_input_m0110

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/input/input.h>
#include <zephyr/pm/device.h>
#include <zephyr/pm/device_runtime.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/util.h>
#include <zephyr/irq.h>

#include "m0110_decode.h"

#if IS_ENABLED(CONFIG_ZMK_USB)
#include <zmk/usb.h>
#endif

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

// True when the board is running off USB bus power.
static inline bool m0110_on_usb_power(void) {
#if IS_ENABLED(CONFIG_ZMK_USB)
    return zmk_usb_is_powered();
#else
    return false;
#endif
}

// debug purposes, sends timestamp with each input
#if IS_ENABLED(CONFIG_INPUT_M0110_TRACE)
#define M0110_TRACE(fmt, ...) LOG_INF(fmt, ##__VA_ARGS__)
#else
#define M0110_TRACE(fmt, ...) do { } while (0)
#endif

#define M0110_MATRIX_COLUMNS 8
#define M0110_MAX_ROWS      14

// Caps Lock tap tuning since it's a locking switch
#define CAPS_TAP_DWELL_MS   80
#define CAPS_DEBOUNCE_MS    150

static inline bool frame_ok(uint8_t wire) {
    return (wire & 0x01) != 0;
}

#define CLOCK_LO_WAIT_US    1000  // Max wait for clock LOW during bit transfer
#define CLOCK_HI_WAIT_US    1000  // Max wait for clock HIGH during bit transfer
#define DATA_HOLD_US        100   // Hold time after last bit before releasing
#define REQUEST_WAIT_MS     250   // Max wait for keyboard to acknowledge cmd
#define INIT_DELAY_MS       1000  // Keyboard boot time after power-on

// Error-recovery pauses.
#define MIDBYTE_ABORT_MS    10    // Aborted mid-byte: let the keyboard finish it
#define ERROR_RECOVER_MS    100   // Clock never moved: keyboard may be unpowered
#define INQUIRY_WAIT_MS     500   // Cap on waiting for an INQUIRY reply

/*
 * Upper bound on how long the driver will report a key as held without seeing
 * its "break" byte, when no stuck-key-timeout-ms is given in devicetree.
 */
#define DEFAULT_STUCK_KEY_TIMEOUT_MS 10000

// Dedicated thread for the blocking INQUIRY/receive loop
#define M0110_THREAD_STACK_SIZE 1024
#define M0110_THREAD_PRIORITY   K_PRIO_COOP(10)  // Cooperative; yields only at sleep points

struct m0110_config {
    struct gpio_dt_spec data_gpio;   // Bidirectional data line to keyboard
    struct gpio_dt_spec clock_gpio;  // Clock line (keyboard-driven, we interrupt on it)
    struct gpio_dt_spec en_gpio;     // Optional: 5V boost converter enable pin
    k_thread_stack_t *stack;         // Pre-allocated stack for the keyboard thread
    size_t stack_size;
    uint32_t idle_timeout_ms;        // Inactivity before entering power-save mode
    uint32_t peek_interval_ms;       // How often to wake keyboard during power-save
    uint32_t stuck_key_timeout_ms;   // Force-release a key held this long (0 = never)
    uint8_t rows;                    // Virtual matrix row count (14 for M0110A)
    uint8_t columns;                 // Virtual matrix column count (8 for M0110A)
};

struct m0110_data {
    const struct device *dev;        // Back-pointer for ISR -> device lookup
    struct k_thread thread;          // Dedicated keyboard communication thread
    struct k_sem data_ready;         // Signaled by clock ISR when keyboard responds
    struct gpio_callback clock_cb;   // GPIO interrupt callback for clock line
    struct m0110_decoder decoder;    // Wire bytes in, key events out
    uint8_t peeked_wire;             // First byte of a sequence read during a power-save peek
    bool has_peeked_wire;
    uint8_t error;                   // Last protocol error code (0 = no error)
    bool enabled;                    // Scanning active (follows the device power state)
    bool caps_lock_down;             // Physical locking switch state for dedup
    bool power_save;                 // True when 5V boost is off, keyboard unpowered
    int64_t last_key_time;           // Uptime (ms) of last key event, for idle timeout
    int64_t caps_last_ms;            // Uptime (ms) of last accepted caps toggle (debounce)
    uint8_t pressed[M0110_MAX_ROWS];
    uint32_t pressed_at_ms[M0110_MAX_ROWS][M0110_MATRIX_COLUMNS];
};

enum m0110_line {
    M0110_LINE_CLOCK,
    M0110_LINE_DATA,
};

static const struct gpio_dt_spec *line_spec(const struct device *dev, enum m0110_line line) {
    const struct m0110_config *config = dev->config;

    return (line == M0110_LINE_CLOCK) ? &config->clock_gpio : &config->data_gpio;
}

static inline void line_assert(const struct device *dev, enum m0110_line line) {
    gpio_pin_configure_dt(line_spec(dev, line), GPIO_OUTPUT_LOW);
}

static inline void line_float(const struct device *dev, enum m0110_line line) {
    gpio_pin_configure_dt(line_spec(dev, line), GPIO_INPUT | GPIO_PULL_UP);
}

static inline bool line_level(const struct device *dev, enum m0110_line line) {
    return gpio_pin_get_dt(line_spec(dev, line));
}

static inline void bus_idle(const struct device *dev) {
    line_float(dev, M0110_LINE_CLOCK);
    line_float(dev, M0110_LINE_DATA);
}

static inline void bus_request_to_send(const struct device *dev) {
    line_float(dev, M0110_LINE_CLOCK);
    line_assert(dev, M0110_LINE_DATA);
}

// Enable or disable the 5V boost converter via the EN pin (if wired)
static inline void boost_set(const struct device *dev, bool enable) {
    const struct m0110_config *config = dev->config;
    if (config->en_gpio.port != NULL) {
        gpio_pin_set_dt(&config->en_gpio, enable ? 1 : 0);
    }
}

// Wait until a line reaches `level`, or give up.
static int await_line(const struct device *dev, enum m0110_line line,
                      bool level, uint32_t timeout_us) {
    while (timeout_us > 0) {
        if (line_level(dev, line) == level) {
            return 0;
        }
        k_busy_wait(1);
        timeout_us--;
    }

    return line_level(dev, line) == level ? 0 : -ETIMEDOUT;
}

static int await_clock_low_ms(const struct device *dev, uint32_t timeout_ms) {
    while (timeout_ms > 0) {
        if (await_line(dev, M0110_LINE_CLOCK, false, 1000) == 0) {
            return 0;
        }
        timeout_ms--;
    }

    return -ETIMEDOUT;
}

// Clock one byte out to the keyboard. Returns 0, or a negative errno.
static int m0110_write_byte(const struct device *dev, uint8_t data) {
    struct m0110_data *drv_data = dev->data;

    drv_data->error = 0;

    bus_request_to_send(dev);

    if (await_clock_low_ms(dev, REQUEST_WAIT_MS) != 0) {
        drv_data->error = 1;
        LOG_ERR("m0110 write: keyboard never started clocking");
        k_msleep(ERROR_RECOVER_MS);
        bus_idle(dev);
        return -ETIMEDOUT;
    }

    for (uint8_t bit = 0x80; bit != 0; bit >>= 1) {
        if (await_line(dev, M0110_LINE_CLOCK, false, CLOCK_LO_WAIT_US) != 0) {
            drv_data->error = 3;
            LOG_ERR("m0110 write: clock stalled high mid-byte");
            k_msleep(ERROR_RECOVER_MS);
            bus_idle(dev);
            return -ETIMEDOUT;
        }

        if (data & bit) {
            line_float(dev, M0110_LINE_DATA);
        } else {
            line_assert(dev, M0110_LINE_DATA);
        }

        if (await_line(dev, M0110_LINE_CLOCK, true, CLOCK_HI_WAIT_US) != 0) {
            drv_data->error = 4;
            LOG_ERR("m0110 write: clock stalled low mid-byte");
            k_msleep(ERROR_RECOVER_MS);
            bus_idle(dev);
            return -ETIMEDOUT;
        }
    }

    k_busy_wait(DATA_HOLD_US);
    bus_idle(dev);

    return 0;
}

/*
 * Read one byte the keyboard is clocking out.
 * Returns the byte, or a negative errno if it could not be read intact.
 */
static int m0110_read_byte(const struct device *dev)
{
    struct m0110_data *drv_data = dev->data;
    uint8_t data = 0;

    drv_data->error = 0;

    line_float(dev, M0110_LINE_CLOCK);
    line_float(dev, M0110_LINE_DATA);

    if (await_clock_low_ms(dev, REQUEST_WAIT_MS) != 0) {
        drv_data->error = 1;
        LOG_DBG("m0110 read: keyboard never started clocking");
        k_msleep(ERROR_RECOVER_MS);
        bus_idle(dev);
        return -ETIMEDOUT;
    }

    // Receive 8 bits, MSB first.
    // Sample while the clock is still low, then wait for the rising edge.
    for (uint8_t i = 0; i < 8; i++) {
        data <<= 1;

        if (await_line(dev, M0110_LINE_CLOCK, false, CLOCK_LO_WAIT_US) != 0) {
            drv_data->error = 2;
            LOG_ERR("m0110 read: clock stalled high mid-byte");
            k_msleep(ERROR_RECOVER_MS);
            bus_idle(dev);
            return -ETIMEDOUT;
        }

        unsigned int lock = irq_lock();
        bool still_low = !line_level(dev, M0110_LINE_CLOCK);
        bool bit = still_low && line_level(dev, M0110_LINE_DATA);
        irq_unlock(lock);

        if (!still_low) {
            drv_data->error = 4;
            LOG_ERR("m0110 read: preempted out of bit %d's valid window", 7 - i);
            k_msleep(MIDBYTE_ABORT_MS);
            bus_idle(dev);
            return -EIO;
        }

        if (bit) {
            data |= 1;
        }

        if (await_line(dev, M0110_LINE_CLOCK, true, CLOCK_HI_WAIT_US) != 0) {
            drv_data->error = 3;
            LOG_ERR("m0110 read: clock stalled low mid-byte");
            k_msleep(ERROR_RECOVER_MS);
            bus_idle(dev);
            return -ETIMEDOUT;
        }
    }

    bus_idle(dev);

    if (!frame_ok(data)) {
        drv_data->error = 5;
        LOG_ERR("m0110 read: byte 0x%02x has bit 0 clear, so it was misread", data);
        return -EBADMSG;
    }

    return data;
}

static int m0110_read_pending(const struct device *dev) {
    int reply;

    if (m0110_write_byte(dev, M0110_CMD_INSTANT) < 0) {
        return -EIO;
    }

    reply = m0110_read_byte(dev);
    if (reply >= 0 && reply != M0110_REPLY_NO_EVENT) {
        LOG_DBG("m0110 instant: 0x%02x", reply);
    }

    return reply;
}

// Send INQUIRY and wait for the keyboard to respond via clock interrupt.
static int m0110_await_transition(const struct device *dev) {
    struct m0110_data *data = dev->data;
    const struct m0110_config *config = dev->config;

    if (m0110_write_byte(dev, M0110_CMD_INQUIRY) < 0) {
        return -EIO;
    }

    gpio_pin_interrupt_configure_dt(&config->clock_gpio,
                                    GPIO_INT_EDGE_TO_INACTIVE);

    if (k_sem_take(&data->data_ready, K_MSEC(INQUIRY_WAIT_MS)) != 0) {
        gpio_pin_interrupt_configure_dt(&config->clock_gpio, GPIO_INT_DISABLE);
        data->error = 6;
        LOG_WRN("m0110 inquiry: no response within %d ms; resyncing",
                INQUIRY_WAIT_MS);
        bus_idle(dev);
        return -ETIMEDOUT;
    }

    if (!data->enabled) {
        return M0110_REPLY_NO_EVENT;
    }

    int response = m0110_read_byte(dev);

    if (response >= 0 && response != M0110_REPLY_NO_EVENT) {
        LOG_DBG("m0110 inquiry: 0x%02x", response);
    }

    return response;
}

enum m0110_exchange {
    M0110_EXCHANGE_EVENTS,
    M0110_EXCHANGE_IDLE,
    M0110_EXCHANGE_FAILED,
};

static enum m0110_exchange m0110_collect_sequence(const struct device *dev) {
    struct m0110_data *drv_data = dev->data;
    int reply;

    drv_data->error = 0;

    if (drv_data->has_peeked_wire) {
        reply = drv_data->peeked_wire;
        drv_data->has_peeked_wire = false;
    } else {
        reply = m0110_await_transition(dev);

        if (reply < 0) {
            m0110_decoder_interrupted(&drv_data->decoder);
            return M0110_EXCHANGE_FAILED;
        }

        if (reply == M0110_REPLY_NO_EVENT) {
            return M0110_EXCHANGE_IDLE;
        }
    }

    M0110_TRACE("wire %8u  0x%02x", k_uptime_get_32(), reply);

    while (m0110_decoder_feed(&drv_data->decoder, (uint8_t)reply) ==
           M0110_DECODE_WANT_BYTE) {
        reply = m0110_read_pending(dev);

        if (reply >= 0) {
            M0110_TRACE("wire %8u  0x%02x (continued)", k_uptime_get_32(), reply);
        }

        if (reply < 0) {
            m0110_decoder_interrupted(&drv_data->decoder);
            return M0110_EXCHANGE_FAILED;
        }

        if (reply == M0110_REPLY_NO_EVENT) {
            m0110_decoder_interrupted(&drv_data->decoder);
            return M0110_EXCHANGE_EVENTS;
        }
    }

    return M0110_EXCHANGE_EVENTS;
}

static void m0110_report_key(const struct device *dev, uint8_t row, uint8_t col,
                             bool pressed) {
    input_report_abs(dev, INPUT_ABS_X, col, false, K_FOREVER);
    input_report_abs(dev, INPUT_ABS_Y, row, false, K_FOREVER);
    input_report_key(dev, INPUT_BTN_TOUCH, pressed, true, K_FOREVER);
}

static void release_all_keys(const struct device *dev) {
    struct m0110_data *data = dev->data;
    const struct m0110_config *config = dev->config;

    for (uint8_t row = 0; row < config->rows && row < M0110_MAX_ROWS; row++) {
        uint8_t held = data->pressed[row];

        if (!held) {
            continue;
        }

        for (uint8_t col = 0; col < config->columns; col++) {
            if (held & BIT(col)) {
                LOG_WRN("Protocol error: force-releasing stuck key row=%d col=%d",
                        row, col);
                m0110_report_key(dev, row, col, false);
            }
        }
        data->pressed[row] = 0;
    }
}

static void release_stuck_keys(const struct device *dev) {
    struct m0110_data *data = dev->data;
    const struct m0110_config *config = dev->config;

    if (config->stuck_key_timeout_ms == 0) {
        return;
    }

    uint32_t now = k_uptime_get_32();

    for (uint8_t row = 0; row < config->rows && row < M0110_MAX_ROWS; row++) {
        uint8_t held = data->pressed[row];

        if (!held) {
            continue;
        }

        for (uint8_t col = 0; col < config->columns; col++) {
            if (!(held & BIT(col))) {
                continue;
            }

            if ((now - data->pressed_at_ms[row][col]) >
                config->stuck_key_timeout_ms) {
                LOG_WRN("Stuck key: releasing row=%d col=%d held for %u ms",
                        row, col, now - data->pressed_at_ms[row][col]);
                data->pressed[row] &= ~BIT(col);
                m0110_report_key(dev, row, col, false);
            }
        }
    }
}

static void report_key_event(const struct device *dev,
                             const struct m0110_key_event *event) {
  struct m0110_data *data = dev->data;
  const struct m0110_config *config = dev->config;

  bool pressed = !event->released;
  uint8_t code = event->code;

  uint8_t row = code / M0110_MATRIX_COLUMNS;
  uint8_t col = code % M0110_MATRIX_COLUMNS;

  if (row >= config->rows || col >= config->columns) {
    LOG_WRN("Scancode 0x%02x is outside the matrix (row=%d, col=%d)", code, row,
            col);
    return;
  }

  M0110_TRACE("key  %8u  0x%02x %s", k_uptime_get_32(), code,
              pressed ? "down" : "up");

  if (code == M0110_CODE_CAPS_LOCK) {
    int64_t now = k_uptime_get();

    if ((now - data->caps_last_ms) < CAPS_DEBOUNCE_MS) {
      LOG_WRN("Caps Lock: ignoring bounce/echo %dms after toggle",
              (int)(now - data->caps_last_ms));
    } else if (pressed != data->caps_lock_down) {
      data->caps_lock_down = pressed;
      data->caps_last_ms = now;
      LOG_DBG("Caps Lock %s: sending tap", pressed ? "lock" : "unlock");
      m0110_report_key(dev, row, col, true); /* press */
      k_msleep(CAPS_TAP_DWELL_MS);
      m0110_report_key(dev, row, col, false); /* release */
    } else {
      LOG_DBG("Caps Lock %s: duplicate parity ignored",
              pressed ? "lock" : "unlock");
    }
  } else {
    LOG_DBG("Key %s: code=0x%02x row=%d col=%d", pressed ? "press" : "release",
            code, row, col);
    if (row < M0110_MAX_ROWS) {
      if (pressed && (data->pressed[row] & BIT(col))) {
        LOG_WRN("Lost break for row=%d col=%d; synthesising release", row, col);
        m0110_report_key(dev, row, col, false);
      }

      if (pressed) {
        data->pressed[row] |= BIT(col);
        data->pressed_at_ms[row][col] = k_uptime_get_32();
      } else {
        data->pressed[row] &= ~BIT(col);
      }
    }
    m0110_report_key(dev, row, col, pressed);
  }
}

/* GPIO ISR: clock falling edge means the keyboard is starting a response */
static void m0110_clock_isr(const struct device *port,
                            struct gpio_callback *cb,
                            uint32_t pins)
{
    struct m0110_data *data = CONTAINER_OF(cb, struct m0110_data,
                                                 clock_cb);
    const struct m0110_config *config = data->dev->config;

    gpio_pin_interrupt_configure_dt(&config->clock_gpio, GPIO_INT_DISABLE);

    k_sem_give(&data->data_ready);
}

static void m0110_thread_fn(void *p1, void *p2, void *p3) {
    const struct device *dev = p1;
    struct m0110_data *data = dev->data;
    const struct m0110_config *config = dev->config;

    ARG_UNUSED(p2);
    ARG_UNUSED(p3);

    while (1) {
        if (!data->enabled) {
            k_msleep(100);
            continue;
        }

        if (data->power_save) {
            if (m0110_on_usb_power()) {
                boost_set(dev, true);
                k_msleep(INIT_DELAY_MS);
                data->power_save = false;
                data->last_key_time = k_uptime_get();
                k_sem_reset(&data->data_ready);
                LOG_INF("M0110 on USB power: leaving power-save");
                continue;
            }

            boost_set(dev, true);
            k_msleep(INIT_DELAY_MS);

            int peek = m0110_read_pending(dev);

            if (peek >= 0 && peek != M0110_REPLY_NO_EVENT) {
                data->power_save = false;
                data->last_key_time = k_uptime_get();
                k_sem_reset(&data->data_ready);
                data->peeked_wire = (uint8_t)peek;
                data->has_peeked_wire = true;
                LOG_INF("M0110 wake: key activity detected");
            } else {
                boost_set(dev, false);
                k_msleep(config->peek_interval_ms);
            }
            continue;
        }

        enum m0110_exchange outcome = m0110_collect_sequence(dev);
        struct m0110_key_event event;
        bool reported = false;

        while (m0110_decoder_next(&data->decoder, &event)) {
            report_key_event(dev, &event);
            reported = true;
        }

        if (reported) {
            data->last_key_time = k_uptime_get();
        }

        if (data->error) {
            release_all_keys(dev);
        }

        release_stuck_keys(dev);

        if (outcome == M0110_EXCHANGE_IDLE && config->en_gpio.port != NULL) {
            int64_t idle_ms = k_uptime_get() - data->last_key_time;
            if (!m0110_on_usb_power() &&
                idle_ms > (int64_t)config->idle_timeout_ms) {
                LOG_INF("M0110 idle timeout (%u ms): disabling 5V boost",
                        config->idle_timeout_ms);
                boost_set(dev, false);
                data->power_save = true;
            }
        }
    }
}

static int m0110_start(const struct device *dev) {
    struct m0110_data *data = dev->data;

    k_sem_reset(&data->data_ready);
    data->enabled = true;
    data->power_save = false;
    data->last_key_time = k_uptime_get();
    boost_set(dev, true);

    return 0;
}

static int m0110_stop(const struct device *dev) {
    struct m0110_data *data = dev->data;
    const struct m0110_config *config = dev->config;

    data->enabled = false;
    gpio_pin_interrupt_configure_dt(&config->clock_gpio, GPIO_INT_DISABLE);

    // Wake the thread so it sees enabled=false
    k_sem_give(&data->data_ready);

    return 0;
}

#if IS_ENABLED(CONFIG_PM_DEVICE)

static int m0110_pm_action(const struct device *dev, enum pm_device_action action) {
    switch (action) {
    case PM_DEVICE_ACTION_RESUME:
        return m0110_start(dev);
    case PM_DEVICE_ACTION_SUSPEND:
        return m0110_stop(dev);
    default:
        return -ENOTSUP;
    }
}

#endif

// Device init
static int m0110_init(const struct device *dev) {
    struct m0110_data *data = dev->data;
    const struct m0110_config *config = dev->config;
    int ret;

    data->dev = dev;
    m0110_decoder_reset(&data->decoder);
    data->peeked_wire = 0;
    data->has_peeked_wire = false;
    data->error = 0;
    data->enabled = false;
    data->caps_lock_down = false;
    data->power_save = false;
    data->last_key_time = 0;
    data->caps_last_ms = 0;

    for (uint8_t i = 0; i < M0110_MAX_ROWS; i++) {
        data->pressed[i] = 0;
        for (uint8_t j = 0; j < M0110_MATRIX_COLUMNS; j++) {
            data->pressed_at_ms[i][j] = 0;
        }
    }

    k_sem_init(&data->data_ready, 0, 1);

    if (!gpio_is_ready_dt(&config->data_gpio)) {
        LOG_ERR("Data GPIO not ready");
        return -ENODEV;
    }

    if (!gpio_is_ready_dt(&config->clock_gpio)) {
        LOG_ERR("Clock GPIO not ready");
        return -ENODEV;
    }

    ret = gpio_pin_configure_dt(&config->data_gpio, GPIO_INPUT | GPIO_PULL_UP);
    if (ret < 0) {
        LOG_ERR("Failed to configure data GPIO: %d", ret);
        return ret;
    }

    ret = gpio_pin_configure_dt(&config->clock_gpio, GPIO_INPUT | GPIO_PULL_UP);
    if (ret < 0) {
        LOG_ERR("Failed to configure clock GPIO: %d", ret);
        return ret;
    }

    if (config->en_gpio.port != NULL) {
        if (!gpio_is_ready_dt(&config->en_gpio)) {
            LOG_ERR("EN GPIO not ready");
            return -ENODEV;
        }
        ret = gpio_pin_configure_dt(&config->en_gpio, GPIO_OUTPUT_ACTIVE);
        if (ret < 0) {
            LOG_ERR("Failed to configure EN GPIO: %d", ret);
            return ret;
        }
        LOG_INF("5V boost EN pin configured (idle timeout: %u ms)",
                config->idle_timeout_ms);
    }

    gpio_init_callback(&data->clock_cb, m0110_clock_isr,
                       BIT(config->clock_gpio.pin));
    ret = gpio_add_callback_dt(&config->clock_gpio, &data->clock_cb);
    if (ret < 0) {
        LOG_ERR("Failed to add clock GPIO callback: %d", ret);
        return ret;
    }

    bus_idle(dev);
    k_msleep(INIT_DELAY_MS);
    k_thread_create(&data->thread, config->stack, config->stack_size,
                    m0110_thread_fn, (void *)dev, NULL, NULL,
                    M0110_THREAD_PRIORITY, 0, K_NO_WAIT);
    k_thread_name_set(&data->thread, "m0110");

    LOG_INF("M0110 keyboard driver initialized (interrupt-driven)");

#if IS_ENABLED(CONFIG_PM_DEVICE)
    pm_device_init_suspended(dev);

#if IS_ENABLED(CONFIG_PM_DEVICE_RUNTIME)
    pm_device_runtime_enable(dev);
#endif

#else
    m0110_start(dev);
#endif

    return 0;
}

#define M0110_INIT(n)                                                    \
    K_THREAD_STACK_DEFINE(m0110_stack_##n, M0110_THREAD_STACK_SIZE);            \
    static struct m0110_data m0110_data_##n;                        \
                                                                               \
    static const struct m0110_config m0110_config_##n = {          \
        .data_gpio = GPIO_DT_SPEC_INST_GET(n, data_gpios),                     \
        .clock_gpio = GPIO_DT_SPEC_INST_GET(n, clock_gpios),                   \
        .en_gpio = COND_CODE_1(DT_INST_NODE_HAS_PROP(n, en_gpios),            \
                               (GPIO_DT_SPEC_INST_GET(n, en_gpios)),           \
                               ({.port = NULL})),                              \
        .stack = m0110_stack_##n,                                               \
        .stack_size = M0110_THREAD_STACK_SIZE,                                  \
        .idle_timeout_ms = DT_INST_PROP(n, idle_timeout_ms),                   \
        .peek_interval_ms = DT_INST_PROP(n, peek_interval_ms),                \
        .stuck_key_timeout_ms = DT_INST_PROP_OR(n, stuck_key_timeout_ms,       \
                                    DEFAULT_STUCK_KEY_TIMEOUT_MS),             \
        .rows = DT_INST_PROP(n, rows),                                         \
        .columns = DT_INST_PROP(n, columns),                                   \
    };                                                                         \
                                                                               \
    PM_DEVICE_DT_INST_DEFINE(n, m0110_pm_action);                              \
                                                                               \
    DEVICE_DT_INST_DEFINE(n, m0110_init, PM_DEVICE_DT_INST_GET(n),       \
                          &m0110_data_##n,                               \
                          &m0110_config_##n,                             \
                          POST_KERNEL,                                         \
                          CONFIG_INPUT_INIT_PRIORITY,                          \
                          NULL);

DT_INST_FOREACH_STATUS_OKAY(M0110_INIT)
