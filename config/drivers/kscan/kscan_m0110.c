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

/* Thread configuration */
#define M0110_THREAD_STACK_SIZE 1024
#define M0110_THREAD_PRIORITY   K_PRIO_COOP(10)

struct kscan_m0110_config {
    struct gpio_dt_spec data_gpio;
    struct gpio_dt_spec clock_gpio;
    struct gpio_dt_spec en_gpio; /* optional: 5V boost EN pin */
    k_thread_stack_t *stack;
    size_t stack_size;
    uint32_t idle_timeout_ms;
    uint32_t peek_interval_ms;
    uint8_t rows;
    uint8_t columns;
};

struct kscan_m0110_data {
    const struct device *dev;
    kscan_callback_t callback;
    struct k_thread thread;
    struct k_sem data_ready;
    struct gpio_callback clock_cb;
    uint8_t keybuf;
    uint8_t keybuf2;
    uint8_t rawbuf;
    uint8_t error;
    bool enabled;
    bool caps_lock_down; /* physical locking switch state */
    bool power_save;     /* 5V boost disabled to save power */
    int64_t last_key_time;
};

/* Forward declarations */
static int m0110_send(const struct device *dev, uint8_t data);
static uint8_t m0110_recv(const struct device *dev);

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

/* Enable or disable the 5V boost converter via the EN pin (if wired) */
static inline void boost_set(const struct device *dev, bool enable)
{
    const struct kscan_m0110_config *config = dev->config;
    if (config->en_gpio.port != NULL) {
        gpio_pin_set_dt(&config->en_gpio, enable ? 1 : 0);
    }
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

/* Send INSTANT command and get response (used for follow-up bytes) */
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
 * Send INQUIRY and wait for the keyboard to respond via clock interrupt.
 *
 * The INQUIRY command (0x10) tells the keyboard to reply when a key event
 * occurs, or with NULL (0x7B) after 250 ms.  Instead of busy-waiting for the
 * response we arm a falling-edge interrupt on the clock line and block on a
 * semaphore, allowing the CPU to sleep until the keyboard pulls clock low to
 * start clocking out its response.
 *
 * The first clock LOW period lasts ~160 µs (per Apple's protocol spec), which
 * gives the thread ample time to resume from the semaphore and enter
 * m0110_recv() before the first bit's rising edge.
 */
static uint8_t m0110_inquiry_recv(const struct device *dev)
{
    struct kscan_m0110_data *data = dev->data;
    const struct kscan_m0110_config *config = dev->config;

    /* Send INQUIRY command */
    if (m0110_send(dev, M0110_INQUIRY) < 0) {
        return M0110_ERROR;
    }

    /* Arm clock interrupt — keyboard pulls clock low when it has data */
    gpio_pin_interrupt_configure_dt(&config->clock_gpio,
                                    GPIO_INT_EDGE_TO_INACTIVE);

    /* Block until keyboard responds (key event or 250ms NULL timeout) */
    k_sem_take(&data->data_ready, K_FOREVER);

    /* Woken by disable_callback, not by keyboard */
    if (!data->enabled) {
        return M0110_NULL;
    }

    /* Clock is already low — read the 8-bit response */
    uint8_t response = m0110_recv(dev);

    if (response != M0110_NULL && response != M0110_ERROR) {
        LOG_DBG("m0110_inquiry: 0x%02x", response);
    }

    return response;
}

/* Clear all key buffers — call on any protocol error to prevent stuck keys */
static void clear_buffers(struct kscan_m0110_data *data)
{
    data->keybuf  = 0x00;
    data->keybuf2 = 0x00;
    data->rawbuf  = 0x00;
}

/*
 * Receive a key event with proper handling of M0110A special cases.
 *
 * The first byte of each key event is obtained via INQUIRY (interrupt-driven,
 * CPU sleeps while waiting).  Follow-up bytes in multi-byte sequences (shift +
 * keypad combos) use INSTANT for immediate response.
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
        raw = m0110_inquiry_recv(dev);
    }

    switch (KEY(raw)) {
        case M0110_KEYPAD:
            /* Keypad prefix - get the actual key */
            raw2 = m0110_instant(dev);
            if (raw2 == M0110_ERROR || raw2 == M0110_NULL) {
                clear_buffers(drv_data);
                return M0110_NULL;
            }
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
            if (raw2 == M0110_ERROR) {
                clear_buffers(drv_data);
                return RAW2SCAN(raw); /* best-effort: return shift alone */
            }
            if (raw2 == M0110_NULL) {
                /* No follow-up key: shift stands alone */
                return RAW2SCAN(raw);
            }
            switch (KEY(raw2)) {
                case M0110_SHIFT:
                    /* Double shift - buffer second and return first */
                    drv_data->rawbuf = raw2;
                    return RAW2SCAN(raw);

                case M0110_KEYPAD:
                    /* Shift + keypad combo */
                    raw3 = m0110_instant(dev);
                    if (raw3 == M0110_ERROR || raw3 == M0110_NULL) {
                        clear_buffers(drv_data);
                        return RAW2SCAN(raw);
                    }
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
                    /*
                     * Shift + normal key. Put raw2 back in rawbuf so it is
                     * processed naturally next iteration, preventing it from
                     * getting stuck in keybuf if the connection drops.
                     */
                    drv_data->rawbuf = raw2;
                    return RAW2SCAN(raw);
            }

        default:
            /* Normal key */
            return RAW2SCAN(raw);
    }
}

/* Process a single scancode and fire the kscan callback */
static void process_scancode(const struct device *dev, uint8_t scancode)
{
    struct kscan_m0110_data *data = dev->data;
    const struct kscan_m0110_config *config = dev->config;

    bool pressed = !(scancode & 0x80);
    uint8_t code = scancode & 0x7F;

    /* Convert scancode to row/column */
    uint8_t row = (code >> 3) & 0x0F;
    uint8_t col = code & 0x07;

    if (row >= config->rows || col >= config->columns) {
        LOG_WRN("Invalid scancode 0x%02x (row=%d, col=%d)", code, row, col);
        return;
    }

    /*
     * Special handling for locking Caps Lock key:
     * The M0110 has a physically locking caps lock switch that sends a make
     * code when it latches and a break code when it releases.  The OS only
     * toggles on a key *press*, so we send a tap (press+release) on each
     * state transition.
     *
     * We track the physical state to ignore duplicate make/break events that
     * can occur on BLE reconnection, which would otherwise cause spurious
     * caps lock toggles.
     */
    if (code == M0110_CAPS_LOCK) {
        if (pressed != data->caps_lock_down) {
            data->caps_lock_down = pressed;
            LOG_DBG("Caps Lock %s: sending tap", pressed ? "lock" : "unlock");
            data->callback(dev, row, col, true);   /* press */
            data->callback(dev, row, col, false);  /* release */
        } else {
            LOG_DBG("Caps Lock %s: duplicate event ignored",
                    pressed ? "lock" : "unlock");
        }
    } else {
        LOG_DBG("Key %s: scancode=0x%02x row=%d col=%d",
                pressed ? "press" : "release", code, row, col);
        data->callback(dev, row, col, pressed);
    }
}

/* GPIO ISR: clock falling edge means the keyboard is starting a response */
static void m0110_clock_isr(const struct device *port,
                            struct gpio_callback *cb,
                            uint32_t pins)
{
    struct kscan_m0110_data *data = CONTAINER_OF(cb, struct kscan_m0110_data,
                                                 clock_cb);
    const struct kscan_m0110_config *config = data->dev->config;

    /* Disable interrupt during data reception */
    gpio_pin_interrupt_configure_dt(&config->clock_gpio, GPIO_INT_DISABLE);

    /* Wake the keyboard thread */
    k_sem_give(&data->data_ready);
}

/*
 * Keyboard thread — replaces the old polling work handler.
 *
 * Normal mode: sends INQUIRY, sleeps until the keyboard responds (or 250ms
 * NULL timeout), reads the response, processes any key events, and loops.
 *
 * Power-save mode (when EN GPIO is wired): after idle_timeout_ms with no key
 * activity, the 5V boost is disabled and the M0110 keyboard powers off.  The
 * thread then periodically re-enables 5V, waits for the keyboard to boot,
 * sends a quick INSTANT to check for activity, and powers back down if idle.
 */
static void m0110_thread_fn(void *p1, void *p2, void *p3)
{
    const struct device *dev = p1;
    struct kscan_m0110_data *data = dev->data;
    const struct kscan_m0110_config *config = dev->config;

    ARG_UNUSED(p2);
    ARG_UNUSED(p3);

    while (1) {
        if (!data->enabled || !data->callback) {
            k_msleep(100);
            continue;
        }

        /*
         * Power-save mode: 5V boost is off, M0110 is unpowered.
         * Periodically wake the keyboard to check for activity.
         */
        if (data->power_save) {
            boost_set(dev, true);
            k_msleep(INIT_DELAY_MS); /* wait for M0110 MCU to boot */

            uint8_t raw = m0110_instant(dev);

            if (raw != M0110_NULL && raw != M0110_ERROR) {
                /* Key detected — exit power save */
                data->power_save = false;
                data->last_key_time = k_uptime_get();
                k_sem_reset(&data->data_ready);
                data->rawbuf = raw; /* process on next recv_key call */
                LOG_INF("M0110 wake: key activity detected");
            } else {
                /* Still idle — power down and sleep */
                boost_set(dev, false);
                k_msleep(config->peek_interval_ms);
            }
            continue;
        }

        /* Normal mode: INQUIRY-based, CPU sleeps between events */
        uint8_t scancode = m0110_recv_key(dev);

        if (scancode != M0110_NULL && scancode != M0110_ERROR) {
            data->last_key_time = k_uptime_get();
            process_scancode(dev, scancode);
        } else if (config->en_gpio.port != NULL) {
            /* Check whether we've been idle long enough to power down */
            int64_t idle_ms = k_uptime_get() - data->last_key_time;
            if (idle_ms > (int64_t)config->idle_timeout_ms) {
                LOG_INF("M0110 idle timeout (%u ms): disabling 5V boost",
                        config->idle_timeout_ms);
                boost_set(dev, false);
                data->power_save = true;
            }
        }
    }
}

/* KSCAN API: configure callback */
static int kscan_m0110_configure(const struct device *dev,
                                 kscan_callback_t callback)
{
    struct kscan_m0110_data *data = dev->data;
    data->callback = callback;
    return 0;
}

/* KSCAN API: enable scanning */
static int kscan_m0110_enable_callback(const struct device *dev)
{
    struct kscan_m0110_data *data = dev->data;

    k_sem_reset(&data->data_ready);
    data->enabled = true;
    data->power_save = false;
    data->last_key_time = k_uptime_get();
    boost_set(dev, true);

    return 0;
}

/* KSCAN API: disable scanning */
static int kscan_m0110_disable_callback(const struct device *dev)
{
    struct kscan_m0110_data *data = dev->data;
    const struct kscan_m0110_config *config = dev->config;

    data->enabled = false;
    gpio_pin_interrupt_configure_dt(&config->clock_gpio, GPIO_INT_DISABLE);

    /* Wake the thread so it sees enabled=false */
    k_sem_give(&data->data_ready);

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
    data->caps_lock_down = false;
    data->power_save = false;
    data->last_key_time = 0;

    k_sem_init(&data->data_ready, 0, 1);

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

    /* Configure optional EN GPIO for 5V boost power management */
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

    /* Configure clock GPIO interrupt callback (not yet enabled) */
    gpio_init_callback(&data->clock_cb, m0110_clock_isr,
                       BIT(config->clock_gpio.pin));
    ret = gpio_add_callback_dt(&config->clock_gpio, &data->clock_cb);
    if (ret < 0) {
        LOG_ERR("Failed to add clock GPIO callback: %d", ret);
        return ret;
    }

    /* Initialize to idle state */
    idle(dev);

    /* Wait for keyboard to initialize */
    k_msleep(INIT_DELAY_MS);

    /* Start the keyboard thread */
    k_thread_create(&data->thread, config->stack, config->stack_size,
                    m0110_thread_fn, (void *)dev, NULL, NULL,
                    M0110_THREAD_PRIORITY, 0, K_NO_WAIT);
    k_thread_name_set(&data->thread, "m0110");

    LOG_INF("M0110 keyboard driver initialized (interrupt-driven)");

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
    K_THREAD_STACK_DEFINE(m0110_stack_##n, M0110_THREAD_STACK_SIZE);            \
    static struct kscan_m0110_data kscan_m0110_data_##n;                        \
                                                                               \
    static const struct kscan_m0110_config kscan_m0110_config_##n = {          \
        .data_gpio = GPIO_DT_SPEC_INST_GET(n, data_gpios),                     \
        .clock_gpio = GPIO_DT_SPEC_INST_GET(n, clock_gpios),                   \
        .en_gpio = COND_CODE_1(DT_INST_NODE_HAS_PROP(n, en_gpios),            \
                               (GPIO_DT_SPEC_INST_GET(n, en_gpios)),           \
                               ({.port = NULL})),                              \
        .stack = m0110_stack_##n,                                               \
        .stack_size = M0110_THREAD_STACK_SIZE,                                  \
        .idle_timeout_ms = DT_INST_PROP(n, idle_timeout_ms),                   \
        .peek_interval_ms = DT_INST_PROP(n, peek_interval_ms),                \
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
