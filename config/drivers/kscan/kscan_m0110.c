/*
 * Copyright (c) 2024 M0110 ZMK Driver
 * Based on TMK m0110.c by Jun Wako <wakojun@gmail.com>
 *
 * SPDX-License-Identifier: MIT
 */

#define DT_DRV_COMPAT zmk_kscan_m0110

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/kscan.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/util.h>

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

/* M0110 Commands */
#define M0110_INQUIRY       0x10
#define M0110_INSTANT       0x14
#define M0110_MODEL         0x16
#define M0110_TEST          0x36

/* M0110 Response codes */
#define M0110_NULL          0x7B
#define M0110_KEYPAD        0x79
#define M0110_TEST_ACK      0x7D
#define M0110_TEST_NAK      0x77
#define M0110_SHIFT         0x71
#define M0110_ARROW_UP      0x1B
#define M0110_ARROW_DOWN    0x11
#define M0110_ARROW_LEFT    0x0D
#define M0110_ARROW_RIGHT   0x05

/* Error indicator */
#define M0110_ERROR         0xFF

/* Scan code offsets for keypad and arrow/calc keys */
#define M0110_KEYPAD_OFFSET 0x40
#define M0110_CALC_OFFSET   0x60

/* Caps Lock scancode (row 7, col 1) - locking key needs special handling */
#define M0110_CAPS_LOCK     0x39

/* Macros for key processing */
#define KEY(raw)        ((raw) & 0x7f)
#define IS_BREAK(raw)   (((raw) & 0x80) == 0x80)

/* Convert raw code to scan code: ((raw&0x80) | ((raw&0x7F)>>1)) */
#define RAW2SCAN(raw)   (((raw) == M0110_NULL) ? M0110_NULL : \
                         (((raw) == M0110_ERROR) ? M0110_ERROR : \
                          (((raw) & 0x80) | (((raw) & 0x7F) >> 1))))

/* Timing constants (microseconds) */
#define CLOCK_LO_WAIT_US    250
#define CLOCK_HI_WAIT_US    200
#define DATA_HOLD_US        100
#define REQUEST_WAIT_MS     250
#define INIT_DELAY_MS       1000

struct kscan_m0110_config {
    struct gpio_dt_spec data_gpio;
    struct gpio_dt_spec clock_gpio;
    uint32_t poll_period_ms;
    uint8_t rows;
    uint8_t columns;
};

struct kscan_m0110_data {
    const struct device *dev;
    kscan_callback_t callback;
    struct k_work_delayable work;
    uint8_t keybuf;
    uint8_t keybuf2;
    uint8_t rawbuf;
    uint8_t error;
    bool enabled;
};

/* Forward declarations */
static int m0110_send(const struct device *dev, uint8_t data);
static uint8_t m0110_recv(const struct device *dev);
static uint8_t m0110_recv_key(const struct device *dev);

/* GPIO helpers */
static inline void clock_lo(const struct device *dev)
{
    const struct kscan_m0110_config *config = dev->config;
    gpio_pin_configure_dt(&config->clock_gpio, GPIO_OUTPUT_LOW);
}

static inline void clock_hi(const struct device *dev)
{
    const struct kscan_m0110_config *config = dev->config;
    gpio_pin_configure_dt(&config->clock_gpio, GPIO_INPUT | GPIO_PULL_UP);
}

static inline bool clock_in(const struct device *dev)
{
    const struct kscan_m0110_config *config = dev->config;
    gpio_pin_configure_dt(&config->clock_gpio, GPIO_INPUT | GPIO_PULL_UP);
    k_busy_wait(1);
    return gpio_pin_get_dt(&config->clock_gpio);
}

static inline void data_lo(const struct device *dev)
{
    const struct kscan_m0110_config *config = dev->config;
    gpio_pin_configure_dt(&config->data_gpio, GPIO_OUTPUT_LOW);
}

static inline void data_hi(const struct device *dev)
{
    const struct kscan_m0110_config *config = dev->config;
    gpio_pin_configure_dt(&config->data_gpio, GPIO_INPUT | GPIO_PULL_UP);
}

static inline bool data_in(const struct device *dev)
{
    const struct kscan_m0110_config *config = dev->config;
    gpio_pin_configure_dt(&config->data_gpio, GPIO_INPUT | GPIO_PULL_UP);
    k_busy_wait(1);
    return gpio_pin_get_dt(&config->data_gpio);
}

static inline void idle(const struct device *dev)
{
    clock_hi(dev);
    data_hi(dev);
}

static inline void request(const struct device *dev)
{
    clock_hi(dev);
    data_lo(dev);
}

/* Wait for clock to go low, returns remaining microseconds or 0 on timeout */
static uint16_t wait_clock_lo(const struct device *dev, uint16_t us)
{
    while (clock_in(dev) && us) {
        k_busy_wait(1);
        us--;
    }
    return us;
}

/* Wait for clock to go high, returns remaining microseconds or 0 on timeout */
static uint16_t wait_clock_hi(const struct device *dev, uint16_t us)
{
    while (!clock_in(dev) && us) {
        k_busy_wait(1);
        us--;
    }
    return us;
}

/* Wait for clock low with millisecond timeout */
static bool wait_clock_lo_ms(const struct device *dev, uint16_t ms)
{
    while (ms) {
        if (wait_clock_lo(dev, 1000)) {
            return true;
        }
        ms--;
    }
    return false;
}

/* Send a byte to the keyboard */
static int m0110_send(const struct device *dev, uint8_t data)
{
    struct kscan_m0110_data *drv_data = dev->data;

    drv_data->error = 0;

    /* Request to send */
    request(dev);

    /* Wait for keyboard to pull clock low (may take a while) */
    if (!wait_clock_lo_ms(dev, REQUEST_WAIT_MS)) {
        drv_data->error = 1;
        LOG_ERR("m0110_send: timeout waiting for clock low");
        k_msleep(500);
        idle(dev);
        return -ETIMEDOUT;
    }

    /* Send 8 bits, MSB first */
    for (uint8_t bit = 0x80; bit; bit >>= 1) {
        if (!wait_clock_lo(dev, CLOCK_LO_WAIT_US)) {
            drv_data->error = 3;
            LOG_ERR("m0110_send: timeout during bit send (clock low)");
            k_msleep(500);
            idle(dev);
            return -ETIMEDOUT;
        }

        if (data & bit) {
            data_hi(dev);
        } else {
            data_lo(dev);
        }

        if (!wait_clock_hi(dev, CLOCK_HI_WAIT_US)) {
            drv_data->error = 4;
            LOG_ERR("m0110_send: timeout during bit send (clock high)");
            k_msleep(500);
            idle(dev);
            return -ETIMEDOUT;
        }
    }

    /* Hold last bit for 80-100us */
    k_busy_wait(DATA_HOLD_US);
    idle(dev);

    return 0;
}

/* Receive a byte from the keyboard */
static uint8_t m0110_recv(const struct device *dev)
{
    struct kscan_m0110_data *drv_data = dev->data;
    uint8_t data = 0;

    drv_data->error = 0;

    /* Wait for keyboard to start sending (clock goes low) */
    if (!wait_clock_lo_ms(dev, REQUEST_WAIT_MS)) {
        drv_data->error = 1;
        LOG_DBG("m0110_recv: timeout waiting for clock low");
        k_msleep(500);
        idle(dev);
        return M0110_ERROR;
    }

    /* Receive 8 bits, MSB first */
    for (uint8_t i = 0; i < 8; i++) {
        data <<= 1;

        if (!wait_clock_lo(dev, CLOCK_HI_WAIT_US)) {
            drv_data->error = 2;
            LOG_ERR("m0110_recv: timeout during bit receive (clock low)");
            k_msleep(500);
            idle(dev);
            return M0110_ERROR;
        }

        if (!wait_clock_hi(dev, CLOCK_HI_WAIT_US)) {
            drv_data->error = 3;
            LOG_ERR("m0110_recv: timeout during bit receive (clock high)");
            k_msleep(500);
            idle(dev);
            return M0110_ERROR;
        }

        if (data_in(dev)) {
            data |= 1;
        }
    }

    idle(dev);
    return data;
}

/* Send INSTANT command and get response */
static uint8_t m0110_instant(const struct device *dev)
{
    if (m0110_send(dev, M0110_INSTANT) < 0) {
        return M0110_ERROR;
    }
    uint8_t data = m0110_recv(dev);
    if (data != M0110_NULL && data != M0110_ERROR) {
        LOG_DBG("m0110_instant: 0x%02x", data);
    }
    return data;
}

/*
 * Receive a key event with proper handling of M0110A special cases.
 * The M0110A has complex behavior for shift+keypad combinations.
 * See TMK m0110.c for detailed documentation.
 */
static uint8_t m0110_recv_key(const struct device *dev)
{
    struct kscan_m0110_data *drv_data = dev->data;
    uint8_t raw, raw2, raw3;

    /* Return buffered keys first */
    if (drv_data->keybuf) {
        raw = drv_data->keybuf;
        drv_data->keybuf = 0x00;
        return raw;
    }
    if (drv_data->keybuf2) {
        raw = drv_data->keybuf2;
        drv_data->keybuf2 = 0x00;
        return raw;
    }

    /* Get raw byte from keyboard or buffer */
    if (drv_data->rawbuf) {
        raw = drv_data->rawbuf;
        drv_data->rawbuf = 0x00;
    } else {
        raw = m0110_instant(dev);
    }

    switch (KEY(raw)) {
        case M0110_KEYPAD:
            /* Keypad prefix - get the actual key */
            raw2 = m0110_instant(dev);
            switch (KEY(raw2)) {
                case M0110_ARROW_UP:
                case M0110_ARROW_DOWN:
                case M0110_ARROW_LEFT:
                case M0110_ARROW_RIGHT:
                    if (IS_BREAK(raw2)) {
                        /* Arrow key release - also generates Calc key release */
                        drv_data->keybuf = (RAW2SCAN(raw2) | M0110_CALC_OFFSET);
                        return (RAW2SCAN(raw2) | M0110_KEYPAD_OFFSET);
                    }
                    break;
            }
            /* Regular keypad key */
            return (RAW2SCAN(raw2) | M0110_KEYPAD_OFFSET);

        case M0110_SHIFT:
            /* Shift key or shift+keypad combo */
            raw2 = m0110_instant(dev);
            switch (KEY(raw2)) {
                case M0110_SHIFT:
                    /* Double shift - buffer second and return first */
                    drv_data->rawbuf = raw2;
                    return RAW2SCAN(raw);

                case M0110_KEYPAD:
                    /* Shift + keypad combo */
                    raw3 = m0110_instant(dev);
                    switch (KEY(raw3)) {
                        case M0110_ARROW_UP:
                        case M0110_ARROW_DOWN:
                        case M0110_ARROW_LEFT:
                        case M0110_ARROW_RIGHT:
                            if (IS_BREAK(raw)) {
                                if (IS_BREAK(raw3)) {
                                    /* Shift up, arrow up */
                                    drv_data->keybuf2 = RAW2SCAN(raw);
                                    drv_data->keybuf = (RAW2SCAN(raw3) | M0110_CALC_OFFSET);
                                    return (RAW2SCAN(raw3) | M0110_KEYPAD_OFFSET);
                                } else {
                                    /* Shift up only */
                                    return RAW2SCAN(raw);
                                }
                            } else {
                                if (IS_BREAK(raw3)) {
                                    /* Arrow/calc up */
                                    drv_data->keybuf = (RAW2SCAN(raw3) | M0110_CALC_OFFSET);
                                    return (RAW2SCAN(raw3) | M0110_KEYPAD_OFFSET);
                                } else {
                                    /* Calc down */
                                    return (RAW2SCAN(raw3) | M0110_CALC_OFFSET);
                                }
                            }

                        default:
                            /* Shift + regular keypad */
                            drv_data->keybuf = (RAW2SCAN(raw3) | M0110_KEYPAD_OFFSET);
                            return RAW2SCAN(raw);
                    }

                default:
                    /* Shift + normal key */
                    drv_data->keybuf = RAW2SCAN(raw2);
                    return RAW2SCAN(raw);
            }

        default:
            /* Normal key */
            return RAW2SCAN(raw);
    }
}

/* Work handler for polling */
static void kscan_m0110_work_handler(struct k_work *work)
{
    struct k_work_delayable *dwork = k_work_delayable_from_work(work);
    struct kscan_m0110_data *data = CONTAINER_OF(dwork, struct kscan_m0110_data, work);
    const struct device *dev = data->dev;
    const struct kscan_m0110_config *config = dev->config;

    if (!data->enabled || !data->callback) {
        return;
    }

    uint8_t scancode = m0110_recv_key(dev);

    if (scancode != M0110_NULL && scancode != M0110_ERROR) {
        bool pressed = !(scancode & 0x80);
        uint8_t code = scancode & 0x7F;

        /* Convert scancode to row/column */
        uint8_t row = (code >> 3) & 0x0F;
        uint8_t col = code & 0x07;

        if (row < config->rows && col < config->columns) {
            /*
             * Special handling for locking Caps Lock key:
             * The M0110 has a physically locking caps lock switch.
             * When locked (pressed), we want caps ON.
             * When unlocked (released), we want caps OFF.
             * Since OS toggles caps on key press only, we send a
             * tap (press+release) on both lock and unlock events.
             */
            if (code == M0110_CAPS_LOCK) {
                LOG_DBG("Caps Lock %s: sending tap", pressed ? "lock" : "unlock");
                data->callback(dev, row, col, true);   /* press */
                data->callback(dev, row, col, false);  /* release */
            } else {
                LOG_DBG("Key %s: scancode=0x%02x row=%d col=%d",
                        pressed ? "press" : "release", code, row, col);
                data->callback(dev, row, col, pressed);
            }
        } else {
            LOG_WRN("Invalid scancode 0x%02x (row=%d, col=%d)", code, row, col);
        }
    }

    /* Schedule next poll */
    k_work_reschedule(&data->work, K_MSEC(config->poll_period_ms));
}

/* KSCAN API: configure callback */
static int kscan_m0110_configure(const struct device *dev, kscan_callback_t callback)
{
    struct kscan_m0110_data *data = dev->data;
    data->callback = callback;
    return 0;
}

/* KSCAN API: enable scanning */
static int kscan_m0110_enable_callback(const struct device *dev)
{
    struct kscan_m0110_data *data = dev->data;
    const struct kscan_m0110_config *config = dev->config;

    data->enabled = true;
    k_work_reschedule(&data->work, K_MSEC(config->poll_period_ms));

    return 0;
}

/* KSCAN API: disable scanning */
static int kscan_m0110_disable_callback(const struct device *dev)
{
    struct kscan_m0110_data *data = dev->data;

    data->enabled = false;
    k_work_cancel_delayable(&data->work);

    return 0;
}

/* Device initialization */
static int kscan_m0110_init(const struct device *dev)
{
    struct kscan_m0110_data *data = dev->data;
    const struct kscan_m0110_config *config = dev->config;
    int ret;

    data->dev = dev;
    data->keybuf = 0;
    data->keybuf2 = 0;
    data->rawbuf = 0;
    data->error = 0;
    data->enabled = false;

    /* Configure GPIO pins */
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

    /* Initialize to idle state */
    idle(dev);

    /* Wait for keyboard to initialize */
    k_msleep(INIT_DELAY_MS);

    /* Initialize work item */
    k_work_init_delayable(&data->work, kscan_m0110_work_handler);

    LOG_INF("M0110 keyboard driver initialized");

    return 0;
}

/* KSCAN driver API */
static const struct kscan_driver_api kscan_m0110_api = {
    .config = kscan_m0110_configure,
    .enable_callback = kscan_m0110_enable_callback,
    .disable_callback = kscan_m0110_disable_callback,
};

/* Device instantiation macro */
#define KSCAN_M0110_INIT(n)                                                    \
    static struct kscan_m0110_data kscan_m0110_data_##n;                        \
                                                                               \
    static const struct kscan_m0110_config kscan_m0110_config_##n = {          \
        .data_gpio = GPIO_DT_SPEC_INST_GET(n, data_gpios),                     \
        .clock_gpio = GPIO_DT_SPEC_INST_GET(n, clock_gpios),                   \
        .poll_period_ms = DT_INST_PROP(n, poll_period_ms),                     \
        .rows = DT_INST_PROP(n, rows),                                         \
        .columns = DT_INST_PROP(n, columns),                                   \
    };                                                                         \
                                                                               \
    DEVICE_DT_INST_DEFINE(n, kscan_m0110_init, NULL,                           \
                          &kscan_m0110_data_##n,                               \
                          &kscan_m0110_config_##n,                             \
                          POST_KERNEL,                                         \
                          CONFIG_KSCAN_INIT_PRIORITY,                          \
                          &kscan_m0110_api);

DT_INST_FOREACH_STATUS_OKAY(KSCAN_M0110_INIT)
