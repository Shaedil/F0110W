/*
 * Copyright (c) 2024 M0110 ZMK Driver
 * Based on TMK m0110.c by Jun Wako <wakojun@gmail.com>
 *
 * SPDX-License-Identifier: MIT
 *
 * Apple M0110/M0110A keyboard converter for ZMK (Zephyr RTOS).
 *
 * Protocol overview
 * -----------------
 * The M0110 uses a 2-wire synchronous serial protocol (clock + data).
 * The keyboard drives the clock line; the data line is bidirectional.
 *
 * Wire byte format (keyboard -> host):
 *   Bit 7:    break flag  (1 = release, 0 = press)
 *   Bits 6-1: key code, left-shifted by one
 *   Bit 0:    always 1  (used as a frame check; see FRAME_OK)
 *
 * The host sends commands (INQUIRY, INSTANT, etc.) and the keyboard
 * responds with raw key bytes or special status codes.
 *
 * Multi-byte sequences:
 *   - Keypad / arrow keys are prefixed with 0x79 (KEYPAD prefix).
 *   - Shift + keypad combos are prefixed with 0x71 (SHIFT prefix).
 *
 * This driver converts raw wire bytes to 7-bit scancodes (via RAW2SCAN),
 * then maps each scancode to a virtual 14x8 matrix for ZMK's kscan API:
 *   row = scancode >> 3,  col = scancode & 7
 */

#define DT_DRV_COMPAT zmk_kscan_m0110

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/kscan.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/util.h>
#include <zephyr/irq.h>

#if IS_ENABLED(CONFIG_ZMK_USB)
#include <zmk/usb.h>
#endif

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

/*
 * True when the board is running off USB bus power.
 *
 * The 5V-boost power-save path below is a battery-life feature only.  While USB
 * supplies the rail there is nothing to save, and cutting it is harmful: the
 * M0110's own MCU loses power, so key presses during an unpowered window are
 * lost rather than delayed.
 */
static inline bool m0110_on_usb_power(void)
{
#if IS_ENABLED(CONFIG_ZMK_USB)
    return zmk_usb_is_powered();
#else
    return false;
#endif
}

/*
 * M0110 host-to-keyboard commands.
 * The host sends these to request data or actions from the keyboard.
 */
#define M0110_INQUIRY       0x10  /* Report next key event, or NULL after ~250ms */
#define M0110_INSTANT       0x14  /* Report key state immediately (no wait) */
#define M0110_MODEL         0x16  /* Report keyboard model number */
#define M0110_TEST          0x36  /* Run keyboard self-test */

/*
 * M0110 keyboard-to-host response codes.
 * These are special raw bytes with protocol meaning, not regular key scancodes.
 */
#define M0110_NULL          0x7B  /* No key event pending (INQUIRY timeout) */
#define M0110_KEYPAD        0x79  /* Prefix: next byte is a keypad/arrow key */
#define M0110_TEST_ACK      0x7D  /* Self-test passed */
#define M0110_TEST_NAK      0x77  /* Self-test failed */
#define M0110_SHIFT         0x71  /* Prefix: shift key involved in this event */

/*
 * M0110A arrow key codes (appear after a KEYPAD prefix byte).
 * On the M0110A, arrow keys share silicon with keypad keys and are
 * sent as two-byte sequences: KEYPAD prefix + arrow code.
 */
#define M0110_ARROW_UP      0x1B
#define M0110_ARROW_DOWN    0x11
#define M0110_ARROW_LEFT    0x0D
#define M0110_ARROW_RIGHT   0x05

/* Sentinel value returned by m0110_recv() on communication failure */
#define M0110_ERROR         0xFF

/*
 * Virtual scancode offsets.
 *
 * The M0110 has no physical key matrix; it sends 7-bit scancodes over
 * serial.  This driver creates a virtual 14x8 matrix by splitting each
 * scancode: row = code >> 3, col = code & 0x07.
 *
 * Keypad and arrow keys arrive as multi-byte sequences (prefixed by
 * M0110_KEYPAD).  After conversion, an offset is added to place them
 * in distinct regions of the virtual matrix:
 *
 *   0x00-0x3F  Main keyboard keys  (rows 0-7)
 *   0x40-0x5F  Keypad keys         (rows 8-11,  + KEYPAD_OFFSET)
 *   0x60-0x6F  Arrow/calc keys     (rows 12-13, + CALC_OFFSET)
 */
#define M0110_KEYPAD_OFFSET 0x40
#define M0110_CALC_OFFSET   0x60

/*
 * Upper bound on virtual matrix rows (see `rows`/`columns` in devicetree,
 * 14 for the M0110A).  Used to size the held-key bitmap that lets us
 * force-release stuck keys after a protocol error.
 */
#define M0110_MAX_ROWS      14

/*
 * Caps Lock scancode after RAW2SCAN conversion.
 * The M0110 has a physically locking caps lock switch, so the driver
 * converts each state transition into a press+release tap for the OS.
 */
#define M0110_CAPS_LOCK     0x39

/*
 * Caps Lock tap tuning.
 *
 * The locking caps switch is emitted to the host as a synthetic press+release
 * "tap" on each latch/unlatch.  macOS applies a minimum-hold filter to Caps
 * Lock, so a zero-length tap is dropped; CAPS_TAP_DWELL_MS holds the key down
 * long enough for the toggle to be accepted (tunable if a host needs longer).
 * A physically locking switch cannot be re-actuated within a fraction of a
 * second, so any caps event arriving within CAPS_DEBOUNCE_MS of the last
 * accepted toggle is line noise or a reconnect echo and is discarded.
 */
#define CAPS_TAP_DWELL_MS   80
#define CAPS_DEBOUNCE_MS    150

/*
 * Raw wire byte layout from the M0110:
 *   Bit 7:    1 = key release (break), 0 = key press (make)
 *   Bits 6-1: key identifier (scancode << 1)
 *   Bit 0:    always 1
 *
 * Bit 0 is a hard invariant rather than a mirror of bit 7: every key code the
 * keyboard can send is odd (A=0x01, S=0x03, Space=0x63, Shift=0x71,
 * Backtick=0x65, ...), as is every protocol response (NULL=0x7B,
 * KEYPAD=0x79, SHIFT=0x71, TEST_ACK=0x7D, TEST_NAK=0x77).  A break byte is its
 * make byte | 0x80, so it is odd too.  That makes bit 0 a free one-bit frame
 * check on every byte; see FRAME_OK() and m0110_recv().
 */
#define KEY(raw)        ((raw) & 0x7f)        /* Strip break bit, keep key ID */
#define IS_BREAK(raw)   (((raw) & 0x80) == 0x80)  /* True if key release */
#define FRAME_OK(raw)   (((raw) & 0x01) == 0x01)  /* Bit 0 invariant holds */

/*
 * Convert raw wire byte to scancode.
 * Preserves the break bit (7) and right-shifts the key ID by 1 to undo
 * the M0110's left-shift encoding.  Passes through NULL and ERROR sentinels.
 */
#define RAW2SCAN(raw)   (((raw) == M0110_NULL) ? M0110_NULL : \
                         (((raw) == M0110_ERROR) ? M0110_ERROR : \
                          (((raw) & 0x80) | (((raw) & 0x7F) >> 1))))

/*
 * Serial protocol timing constants, derived from Apple's M0110 technical spec
 * and validated against real hardware.
 *
 * The keyboard clocks bits at ~5 kHz (~180 us per half-cycle).  The per-bit
 * timeouts below are generous (5-6x nominal) real-microsecond budgets: the
 * sampling loop reads the GPIO directly (~1 us per poll) instead of
 * reconfiguring the pin each time, so the counters track wall-clock time and
 * must allow for slow specimens, noisy lines and interrupt jitter without
 * timing out mid-byte.
 */
#define CLOCK_LO_WAIT_US    1000  /* Max wait for clock LOW during bit xfer */
#define CLOCK_HI_WAIT_US    1000  /* Max wait for clock HIGH during bit xfer */
#define DATA_HOLD_US        100   /* Hold time after last bit before releasing */
#define REQUEST_WAIT_MS     250   /* Max wait for keyboard to acknowledge command */
#define INIT_DELAY_MS       1000  /* Keyboard boot time after power-on */

/*
 * Error-recovery pauses.
 *
 * A failed exchange can leave the keyboard mid-byte or wedged, so we back off
 * before driving the lines again.  These pauses are input blackouts (the M0110
 * only buffers a couple of transitions), so they are sized to the job rather
 * than left generous: one whole byte is ~2.6 ms on the wire (8 bits at
 * ~330 us).  The old blanket 500 ms meant every glitch swallowed half a second
 * of typing, which on BLE (where glitches are far more frequent) was a large
 * part of the perceived unreliability.
 */
#define MIDBYTE_ABORT_MS    10    /* Aborted mid-byte: let the keyboard finish it */
#define ERROR_RECOVER_MS    100   /* Clock never moved: keyboard may be unpowered */
#define INQUIRY_WAIT_MS     500   /* Cap on waiting for an INQUIRY reply (spec: 250) */

/*
 * Upper bound on how long the driver will report a key as held without seeing
 * its "break" byte, when no stuck-key-timeout-ms is given in devicetree.
 *
 * A lost break strands the key down and the *host* auto-repeats it forever.
 * Host auto-repeat is also the only way this keyboard repeats at all, so the
 * timeout must outlast every deliberate hold (holding backspace or an arrow to
 * scroll, a few seconds at most) while still bounding a stranded key to
 * something survivable.
 */
#define DEFAULT_STUCK_KEY_TIMEOUT_MS 10000

/* Dedicated thread for the blocking INQUIRY/receive loop */
#define M0110_THREAD_STACK_SIZE 1024
#define M0110_THREAD_PRIORITY   K_PRIO_COOP(10)  /* Cooperative; yields only at sleep points */

/*
 * Immutable device configuration, populated from devicetree at compile time.
 * One instance per kscan_m0110 node in the devicetree.
 */
struct kscan_m0110_config {
    struct gpio_dt_spec data_gpio;   /* Bidirectional data line to keyboard */
    struct gpio_dt_spec clock_gpio;  /* Clock line (keyboard-driven, we interrupt on it) */
    struct gpio_dt_spec en_gpio;     /* Optional: 5V boost converter enable pin */
    k_thread_stack_t *stack;         /* Pre-allocated stack for the keyboard thread */
    size_t stack_size;
    uint32_t idle_timeout_ms;        /* Inactivity before entering power-save mode */
    uint32_t peek_interval_ms;       /* How often to wake keyboard during power-save */
    uint32_t stuck_key_timeout_ms;   /* Force-release a key held this long (0 = never) */
    uint8_t rows;                    /* Virtual matrix row count (14 for M0110A) */
    uint8_t columns;                 /* Virtual matrix column count (8 for M0110A) */
};

/*
 * Mutable runtime state, one instance per device.
 *
 * Key buffering: the M0110 protocol packs multiple logical key events
 * into single multi-byte exchanges (e.g., shift+keypad = 3 wire bytes
 * but produces separate shift and keypad scancodes).  The driver
 * unpacks these into keybuf/keybuf2 and returns them one per call
 * to m0110_recv_key().  rawbuf holds a raw wire byte that couldn't
 * be fully processed yet (e.g., a second shift byte).
 */
struct kscan_m0110_data {
    const struct device *dev;        /* Back-pointer for ISR -> device lookup */
    kscan_callback_t callback;       /* ZMK kscan callback (row, col, pressed) */
    struct k_thread thread;          /* Dedicated keyboard communication thread */
    struct k_sem data_ready;         /* Signaled by clock ISR when keyboard responds */
    struct gpio_callback clock_cb;   /* GPIO interrupt callback for clock line */
    uint8_t keybuf;                  /* First buffered scancode from multi-byte event */
    uint8_t keybuf2;                 /* Second buffered scancode (shift+arrow combos) */
    uint8_t rawbuf;                  /* Unprocessed raw wire byte for next iteration */
    uint8_t error;                   /* Last protocol error code (0 = no error) */
    bool enabled;                    /* Scanning active (set by enable/disable API) */
    bool caps_lock_down;             /* Physical locking switch state for dedup */
    bool power_save;                 /* True when 5V boost is off, keyboard unpowered */
    int64_t last_key_time;           /* Uptime (ms) of last key event, for idle timeout */
    int64_t caps_last_ms;            /* Uptime (ms) of last accepted caps toggle (debounce) */
    /*
     * Bitmap of positions currently reported to ZMK as held (bit N of
     * pressed[row] = column N).  release_all_keys() walks this to force a
     * release for every held key when the serial link glitches, so a lost
     * "break" byte can't strand a key down and trigger host auto-repeat.
     */
    uint8_t pressed[M0110_MAX_ROWS];
    /*
     * Uptime (ms) at which each held position was last reported pressed, so
     * release_stuck_keys() can expire one whose "break" byte never arrived.
     */
    uint32_t pressed_at_ms[M0110_MAX_ROWS][8];
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

/*
 * Read the clock line.  The pin is left configured as an input for the whole
 * receive (and during send the keyboard drives clock too), so this is a plain
 * register read, not a reconfigure.  Reconfiguring the pin on every sample
 * (the old behaviour) was slow enough that the microsecond busy-wait loops no
 * longer tracked real time and bits could be sampled on the wrong clock phase.
 */
static inline bool clock_read(const struct device *dev)
{
    const struct kscan_m0110_config *config = dev->config;
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

/* Read the data line.  Plain register read; the pin is pre-configured as an
 * input for the duration of reception (see m0110_recv). */
static inline bool data_read(const struct device *dev)
{
    const struct kscan_m0110_config *config = dev->config;
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
    while (clock_read(dev) && us) {
        k_busy_wait(1);
        us--;
    }
    return us;
}

/* Wait for clock to go high, returns remaining microseconds or 0 on timeout */
static uint16_t wait_clock_hi(const struct device *dev, uint16_t us)
{
    while (!clock_read(dev) && us) {
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
        k_msleep(ERROR_RECOVER_MS);
        idle(dev);
        return -ETIMEDOUT;
    }

    /* Send 8 bits, MSB first */
    for (uint8_t bit = 0x80; bit; bit >>= 1) {
        if (!wait_clock_lo(dev, CLOCK_LO_WAIT_US)) {
            drv_data->error = 3;
            LOG_ERR("m0110_send: timeout during bit send (clock low)");
            k_msleep(ERROR_RECOVER_MS);
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
            k_msleep(ERROR_RECOVER_MS);
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
    const struct kscan_m0110_config *config = dev->config;
    uint8_t data = 0;

    drv_data->error = 0;

    /*
     * Both lines are keyboard-driven during reception.  Configure them as
     * inputs once here so the bit loop can sample with plain register reads
     * (clock_read/data_read) rather than reconfiguring the pin per bit.
     */
    gpio_pin_configure_dt(&config->clock_gpio, GPIO_INPUT | GPIO_PULL_UP);
    gpio_pin_configure_dt(&config->data_gpio, GPIO_INPUT | GPIO_PULL_UP);

    /* Wait for keyboard to start sending (clock goes low) */
    if (!wait_clock_lo_ms(dev, REQUEST_WAIT_MS)) {
        drv_data->error = 1;
        LOG_DBG("m0110_recv: timeout waiting for clock low");
        k_msleep(ERROR_RECOVER_MS);
        idle(dev);
        return M0110_ERROR;
    }

    /*
     * Receive 8 bits, MSB first.
     *
     * The data line is only valid while the clock is LOW.  The keyboard sets
     * the bit up after pulling clock low and is free to change it once clock
     * rises again; m0110_send() above follows the same convention, driving
     * data during the clock-low window.
     *
     * Sampling after the rising edge (the previous behaviour) raced that
     * transition and intermittently latched the *next* bit's value.  A flip in
     * bit 7 turns a "break" byte into a "make", so ZMK never sees the release,
     * the key stays logically held, and the host's auto-repeat spams it.  That
     * corruption is silent: the byte still decodes to a valid scancode, so it
     * never sets drv_data->error and release_all_keys() never runs.
     *
     * Sample while the clock is still low, then wait for the rising edge.
     */
    for (uint8_t i = 0; i < 8; i++) {
        data <<= 1;

        if (!wait_clock_lo(dev, CLOCK_LO_WAIT_US)) {
            drv_data->error = 2;
            LOG_ERR("m0110_recv: timeout during bit receive (clock low)");
            k_msleep(ERROR_RECOVER_MS);
            idle(dev);
            return M0110_ERROR;
        }

        /*
         * Latch the bit atomically, and only after re-confirming the clock is
         * still low.
         *
         * The window between "we saw clock go low" and "we sampled data" is a
         * couple of instructions wide, but it is the one place where an
         * interrupt does real damage: if the CPU disappears into an ISR here
         * for longer than the ~160 us clock-low period, the keyboard has moved
         * on to the next bit by the time data_read() executes and we latch the
         * wrong value.  The corruption is again silent: the byte still decodes
         * to a plausible scancode, so nothing downstream notices, and a flipped
         * bit 7 turns a release into a press that ZMK then holds forever while
         * the host auto-repeats it.
         *
         * BLE makes this far more likely than USB because the radio raises the
         * interrupt rate: connection events, and especially the CPU-halting
         * flash writes ZMK does when bonding/profile settings change, are the
         * long preemptions that overrun the window.
         *
         * Masking interrupts for the *whole* byte (~2.6 ms) would be the wrong
         * cure: the Bluetooth link layer needs its radio interrupts serviced on
         * time or the connection drops, and on nRF the controller's radio ISR
         * may be a zero-latency interrupt that irq_lock() cannot mask anyway.
         * A ~2 us lock around the latch closes the same race with no such cost.
         *
         * Re-reading the clock inside the lock also converts the residual
         * failure from silent to detectable: if we were preempted out of the
         * window we abort the byte instead of returning a corrupted one, and
         * the caller's release_all_keys() unwinds any key we might have
         * stranded.
         */
        unsigned int lock = irq_lock();
        bool still_low = !clock_read(dev);
        bool bit = still_low && data_read(dev);
        irq_unlock(lock);

        if (!still_low) {
            drv_data->error = 4;
            LOG_ERR("m0110_recv: preempted out of bit %d's valid window", 7 - i);
            k_msleep(MIDBYTE_ABORT_MS);
            idle(dev);
            return M0110_ERROR;
        }

        if (bit) {
            data |= 1;
        }

        if (!wait_clock_hi(dev, CLOCK_HI_WAIT_US)) {
            drv_data->error = 3;
            LOG_ERR("m0110_recv: timeout during bit receive (clock high)");
            k_msleep(ERROR_RECOVER_MS);
            idle(dev);
            return M0110_ERROR;
        }
    }

    idle(dev);

    /*
     * Frame check: bit 0 of every M0110 response is 1.  A byte that fails this
     * was misread (a slipped or mis-sampled bit) and must be discarded rather
     * than decoded into a scancode.  It costs nothing and catches corruption
     * the per-bit timeouts miss.
     */
    if (!FRAME_OK(data)) {
        drv_data->error = 5;
        LOG_ERR("m0110_recv: frame error, byte 0x%02x has bit 0 clear", data);
        /* The byte completed and the lines are idle, so no back-off needed. */
        return M0110_ERROR;
    }

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
 * The first clock LOW period lasts ~160 us (per Apple's protocol spec), which
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

    /* Arm clock interrupt: keyboard pulls clock low when it has data */
    gpio_pin_interrupt_configure_dt(&config->clock_gpio,
                                    GPIO_INT_EDGE_TO_INACTIVE);

    /*
     * Block until the keyboard responds (key event, or its own ~250 ms NULL
     * timeout).  The wait is bounded rather than K_FOREVER: the falling edge is
     * armed a few microseconds after the command is sent, and if it is ever
     * missed (an early response, or an edge that never latched), a forever-wait
     * would leave the keyboard dead until the board is reset.  INQUIRY is
     * specified to answer within 250 ms, so anything past INQUIRY_WAIT_MS is a
     * failure to recover from rather than wait out.
     */
    if (k_sem_take(&data->data_ready, K_MSEC(INQUIRY_WAIT_MS)) != 0) {
        gpio_pin_interrupt_configure_dt(&config->clock_gpio, GPIO_INT_DISABLE);
        data->error = 6;
        LOG_WRN("m0110_inquiry: no response within %d ms; resyncing",
                INQUIRY_WAIT_MS);
        idle(dev);
        return M0110_ERROR;
    }

    /* Woken by disable_callback, not by keyboard */
    if (!data->enabled) {
        return M0110_NULL;
    }

    /* Clock is already low: read the 8-bit response */
    uint8_t response = m0110_recv(dev);

    if (response != M0110_NULL && response != M0110_ERROR) {
        LOG_DBG("m0110_inquiry: 0x%02x", response);
    }

    return response;
}

/* Clear all key buffers; call on any protocol error to prevent stuck keys */
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

    /*
     * Clear any stale error from a previous exchange.  The thread loop's
     * release-all-on-error safety net keys off drv_data->error, and the
     * buffered-key returns below perform no I/O that would refresh it.
     */
    drv_data->error = 0;

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

/*
 * Force-release every key the driver currently believes is held.
 *
 * The M0110 sends a distinct "make" byte on press and "break" byte on
 * release.  If a break byte is lost or corrupted on the wire, ZMK never sees
 * the release, so the host's key-repeat engages and the keyboard spams the
 * last key pressed.  Calling this whenever a low-level protocol error is
 * detected bounds how long a dropped break can strand a key to a single
 * polling cycle.
 */
static void release_all_keys(const struct device *dev)
{
    struct kscan_m0110_data *data = dev->data;
    const struct kscan_m0110_config *config = dev->config;

    if (!data->callback) {
        return;
    }

    for (uint8_t row = 0; row < config->rows && row < M0110_MAX_ROWS; row++) {
        uint8_t held = data->pressed[row];

        if (!held) {
            continue;
        }

        for (uint8_t col = 0; col < config->columns; col++) {
            if (held & BIT(col)) {
                LOG_WRN("Protocol error: force-releasing stuck key row=%d col=%d",
                        row, col);
                data->callback(dev, row, col, false);
            }
        }
        data->pressed[row] = 0;
    }
}

/*
 * Force-release any key that has been held implausibly long.
 *
 * release_all_keys() only fires when the driver *notices* a protocol error.
 * Corruption that passes every check (a mis-sampled bit 7 that still frames
 * correctly and still names a real key) turns a release into a press with
 * nothing to detect, and ZMK holds that key until the matching break arrives.
 * It never will, so the host auto-repeats the character indefinitely.
 *
 * The bound has to coexist with host auto-repeat, which is the only repeat this
 * keyboard has: holding backspace or an arrow to scroll is a legitimate
 * multi-second hold and must not be cut short.  stuck-key-timeout-ms therefore
 * defaults well above any deliberate hold; it turns "spams forever until I
 * unplug it" into a bounded burst.  Set it to 0 in devicetree to disable.
 *
 * Called once per keyboard-thread iteration.  INQUIRY answers within ~250 ms
 * even when nothing is pressed, so the check runs at least that often.
 */
static void release_stuck_keys(const struct device *dev)
{
    struct kscan_m0110_data *data = dev->data;
    const struct kscan_m0110_config *config = dev->config;

    if (config->stuck_key_timeout_ms == 0 || !data->callback) {
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
                data->callback(dev, row, col, false);
            }
        }
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
     * toggles on a key *press*, so we send a dwelled tap (press, hold,
     * release) on each state transition.
     *
     * The toggle is guarded by a time debounce (CAPS_DEBOUNCE_MS), which drops
     * impossibly-fast repeats from line noise or reconnect echoes (the old
     * "random caps on BLE"), and by a physical-parity check, which drops
     * same-direction duplicates and lets the tracker resync after a dropped
     * make/break byte.
     */
    if (code == M0110_CAPS_LOCK) {
        int64_t now = k_uptime_get();

        if ((now - data->caps_last_ms) < CAPS_DEBOUNCE_MS) {
            /*
             * Too soon after the last accepted toggle for a real locking-switch
             * actuation, so this is line noise or a reconnect echo.  Discard
             * without touching state.
             */
            LOG_WRN("Caps Lock: ignoring bounce/echo %dms after toggle",
                    (int)(now - data->caps_last_ms));
        } else if (pressed != data->caps_lock_down) {
            data->caps_lock_down = pressed;
            data->caps_last_ms = now;
            LOG_DBG("Caps Lock %s: sending tap", pressed ? "lock" : "unlock");
            /*
             * Tap with a dwell so macOS's caps-lock hold-filter accepts it:
             * press, hold CAPS_TAP_DWELL_MS, release.  This runs on the
             * keyboard thread and the M0110 buffers transitions until the next
             * INQUIRY, so the only cost is a brief latency on the key pressed
             * immediately after caps, with no lost input.
             */
            data->callback(dev, row, col, true);   /* press */
            k_msleep(CAPS_TAP_DWELL_MS);
            data->callback(dev, row, col, false);  /* release */
        } else {
            /* Same physical parity as last time: reconnect echo, or a resync
             * after a dropped make/break byte.  No toggle. */
            LOG_DBG("Caps Lock %s: duplicate parity ignored",
                    pressed ? "lock" : "unlock");
        }
    } else {
        LOG_DBG("Key %s: scancode=0x%02x row=%d col=%d",
                pressed ? "press" : "release", code, row, col);
        /*
         * Remember which positions are held so release_all_keys() can clean
         * up if the link glitches.  (Caps Lock is emitted as a momentary tap
         * above, so it is deliberately never recorded here.)
         */
        if (row < M0110_MAX_ROWS) {
            /*
             * A make for a key we already believe is held is proof that its
             * break byte was lost: a real key cannot be pressed twice without
             * an intervening release.  Emit the missing release first so the
             * host's auto-repeat stops and ZMK's position state stays in step,
             * instead of stacking a second press on the stranded one.
             */
            if (pressed && (data->pressed[row] & BIT(col))) {
                LOG_WRN("Lost break for row=%d col=%d; synthesising release",
                        row, col);
                data->callback(dev, row, col, false);
            }

            if (pressed) {
                data->pressed[row] |= BIT(col);
                data->pressed_at_ms[row][col] = k_uptime_get_32();
            } else {
                data->pressed[row] &= ~BIT(col);
            }
        }
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
 * Keyboard thread (replaces the old polling work handler).
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
            /*
             * USB arrived while we were power-saving: restore the rail for good
             * and stop peeking, so no further key presses can be lost.
             */
            if (m0110_on_usb_power()) {
                boost_set(dev, true);
                k_msleep(INIT_DELAY_MS); /* wait for M0110 MCU to boot */
                data->power_save = false;
                data->last_key_time = k_uptime_get();
                k_sem_reset(&data->data_ready);
                LOG_INF("M0110 on USB power: leaving power-save");
                continue;
            }

            boost_set(dev, true);
            k_msleep(INIT_DELAY_MS); /* wait for M0110 MCU to boot */

            uint8_t raw = m0110_instant(dev);

            if (raw != M0110_NULL && raw != M0110_ERROR) {
                /* Key detected: exit power save */
                data->power_save = false;
                data->last_key_time = k_uptime_get();
                k_sem_reset(&data->data_ready);
                data->rawbuf = raw; /* process on next recv_key call */
                LOG_INF("M0110 wake: key activity detected");
            } else {
                /* Still idle: power down and sleep */
                boost_set(dev, false);
                k_msleep(config->peek_interval_ms);
            }
            continue;
        }

        /* Normal mode: INQUIRY-based, CPU sleeps between events */
        uint8_t scancode = m0110_recv_key(dev);

        /*
         * A low-level protocol error during this exchange means we may have
         * missed a key-release byte.  Force-release everything so a dropped
         * "break" can't leave a key stuck (which the host would auto-repeat).
         */
        if (data->error) {
            release_all_keys(dev);
        }

        /* Bound how long any key can stay held without its break byte. */
        release_stuck_keys(dev);

        if (scancode != M0110_NULL && scancode != M0110_ERROR) {
            data->last_key_time = k_uptime_get();
            process_scancode(dev, scancode);
        } else if (scancode == M0110_NULL && config->en_gpio.port != NULL) {
            /* Genuine no-event NULL: check whether we've been idle long
             * enough to power down (errors don't count toward idle).
             * Never power down while USB supplies the rail; see
             * m0110_on_usb_power(). */
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
    data->caps_last_ms = 0;

    for (uint8_t i = 0; i < M0110_MAX_ROWS; i++) {
        data->pressed[i] = 0;
        for (uint8_t j = 0; j < 8; j++) {
            data->pressed_at_ms[i][j] = 0;
        }
    }

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
        .stuck_key_timeout_ms = DT_INST_PROP_OR(n, stuck_key_timeout_ms,       \
                                    DEFAULT_STUCK_KEY_TIMEOUT_MS),             \
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
